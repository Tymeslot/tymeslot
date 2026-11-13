defmodule Tymeslot.MeetingPayments.Webhooks.SeriesCheckoutCompleted do
  @moduledoc """
  `checkout.session.completed` for the one payment of a paid series:
  `Webhooks.CheckoutSessionCompleted` resolves the payment, checks the
  amount and that it is paid, and hands a payment owned by a series here.

  The series is one booking paid at once, so every transition takes all its
  sessions or none:

    * Every session `awaiting_payment`: the payment is recorded paid, each
      session confirmed, given its calendar job and announced as a session
      of a series (`Activation`, `announce: :series`), and the series'
      one confirmation scheduled, all in one transaction. On a type
      requiring approval each session moves to `awaiting_approval` instead,
      every one with the deadline restarted from the first session's
      (`PaymentCompletion.post_payment_status/1`), and the series is
      requested once (`Notifications.schedule_series_request/1`) in place
      of its confirmation: the host is asked only once the money is in.
    * Every session expired and the payment failed (the checkout lapsed
      before the money arrived): the sessions come back only if every one
      of their slots is still free, each counted under the organiser's
      schedule lock (`Scheduling.reinstate_with_conflict_check/2`). One slot
      taken reinstates none, and the whole payment is refunded by
      `Workers.RefundLatePayment`.
    * A host whose account is pending deletion takes no booking: every
      session is left expired and the payment refunded in full.
    * Some sessions released while the rest were held: the series cannot
      go ahead whole, so the held sessions are expired and the payment
      refunded in full, as for a refused booking.
    * Anything else is a no-op, as for a single booking.

  Locks are taken payment first (`LockedPayment`), then the series row,
  then its meetings in series order (`HeldMeetings.lock_series/1`), as in
  every other writer of a paid series. The pages wait on the first
  session's payment topic, so the series is announced there once.
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentCompletion
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Repo

  @doc """
  Completes the series payment `payment` (a paid checkout session
  `object`, delivered as `event_id`). Returns `:ok`, or `{:error, reason}`
  for Stripe (or the reconciler) to try again.
  """
  @spec run(BookingPaymentSchema.t(), String.t(), map()) :: :ok | {:error, term()}
  def run(%BookingPaymentSchema{series_id: series_id} = payment, event_id, object)
      when is_binary(series_id) do
    payment
    |> complete(event_id, object)
    |> settle_outcome(object, log_meta(payment, event_id))
  end

  defp settle_outcome({:ok, {:advanced, paid, meetings, pending}}, object, _meta),
    do: after_payment(paid, meetings, pending, object)

  defp settle_outcome({:ok, {:recovered, paid, meetings, pending}}, object, meta) do
    Logger.warning(
      "checkout.session.completed: series recovered, completed event arrived after expiry",
      meta
    )

    after_payment(paid, meetings, pending, object)
  end

  defp settle_outcome({:ok, {:refund_scheduled, _paid, first}}, _object, meta) do
    Logger.warning(
      "checkout.session.completed: series completed after expiry with a slot taken, refund scheduled",
      meta
    )

    HeldMeetings.broadcast(first.id, :expired)
    :ok
  end

  defp settle_outcome({:ok, {:refused, paid, first}}, object, meta) do
    Logger.warning(
      "checkout.session.completed: series refused (host pending deletion, sessions released or series gone), refund scheduled",
      meta
    )

    PaymentCompletion.backfill_charge_id(paid, object)
    if first, do: HeldMeetings.announce_expired(first)
    :ok
  end

  defp settle_outcome({:ok, outcome}, _object, _meta)
       when outcome in [:no_op, :idempotent_replay],
       do: :ok

  defp settle_outcome({:error, reason} = error, _object, meta) do
    Logger.error(
      "checkout.session.completed handler failed for a series",
      [reason: LogFormat.reason(reason)] ++ meta
    )

    error
  end

  defp log_meta(payment, event_id),
    do: [series_id: payment.series_id, payment_id: payment.id, event_id: event_id]

  defp after_payment(paid, [first | _rest], pending, object) do
    PaymentCompletion.backfill_charge_id(paid, object)
    PaymentCompletion.emit_payment_succeeded(paid, first)
    HeldMeetings.broadcast(first.id, :paid)
    Availability.changed(first.organizer_user_id)
    Activation.after_commit(pending)
  end

  # As for a single booking: the first attempt takes no schedule lock and
  # backs out on finding the sessions expired; the recovery then counts
  # every slot again under the organiser's schedule lock.
  defp complete(payment, event_id, object) do
    case LockedPayment.run(payment, event_id, &in_transaction(&1, event_id, object, :unchecked)) do
      {:error, :slot_unchecked} -> recover(payment, event_id, object)
      result -> result
    end
  end

  defp recover(payment, event_id, object) do
    write_fn = fn ->
      case LockedPayment.run(payment, event_id, &in_transaction(&1, event_id, object, :free)) do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    payment.series_id
    |> BookingSeries.meetings()
    |> reinstate_all(write_fn)
    |> PaymentCompletion.refund_if_slot_lost(fn ->
      refund_late_payment(payment, event_id, object)
    end)
  end

  # Every session's slot is counted free under the schedule lock, one
  # nested in the next, and the payment's transaction runs inside the last:
  # one slot taken rolls every one back, so the series comes back whole or
  # not at all.
  defp reinstate_all([], write_fn), do: Repo.transaction(write_fn)

  defp reinstate_all([meeting], write_fn),
    do: Scheduling.reinstate_with_conflict_check(meeting, write_fn)

  defp reinstate_all([meeting | rest], write_fn) do
    Scheduling.reinstate_with_conflict_check(meeting, fn ->
      case reinstate_all(rest, write_fn) do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Runs under the payment's row lock; the series and its sessions are
  # locked next. `slot` says whether every session's slot has been counted
  # free under the schedule lock, which a recovery needs.
  defp in_transaction(payment, event_id, object, slot) do
    case HeldMeetings.lock_series(payment.series_id) do
      {_series, []} -> refund_orphaned(payment, event_id, object)
      {series, meetings} -> settle(series, meetings, payment, {event_id, object, slot})
    end
  end

  defp settle(series, [first | _rest] = meetings, payment, {event_id, object, slot}) do
    with {:proceed, transition} <- check_transition(meetings, payment),
         :ok <- PaymentCompletion.host_accepting(first),
         :ok <- slot_checked(transition, slot),
         {:ok, paid} <- PaymentCompletion.mark_paid(payment, event_id, object),
         {:ok, confirmed, pending} <- confirm_all(meetings),
         {:ok, _job} <- announce_series(series, confirmed) do
      {:ok, {transition, paid, confirmed, pending}}
    else
      :no_op -> {:ok, :no_op}
      {:refuse, :sessions_released} -> refuse(payment, meetings, event_id, object)
      {:refuse, :host_pending_deletion, _meeting} -> refuse(payment, meetings, event_id, object)
      {:error, _reason} = error -> error
    end
  end

  # A series held for approval is requested now, not confirmed.
  defp announce_series(series, [%{status: :awaiting_approval} | _rest]),
    do: Notifications.schedule_series_request(series)

  defp announce_series(series, _confirmed), do: Notifications.schedule_series_confirmation(series)

  # Each session is confirmed as a single paid booking is, without a
  # confirmation of its own: the series sends one for all of them. The
  # status is the first session's for every one, so a series held for
  # approval shares one deadline, counted from the first session.
  defp confirm_all([first | _rest] = meetings) do
    status = PaymentCompletion.post_payment_status(first)

    result =
      Enum.reduce_while(meetings, {[], []}, fn meeting, {confirmed, pending} ->
        case confirm(meeting, status) do
          {:ok, done, owed} -> {:cont, {[done | confirmed], [owed | pending]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:error, _reason} = error ->
        error

      {confirmed, pending} ->
        {:ok, Enum.reverse(confirmed), pending |> Enum.reverse() |> Enum.concat()}
    end
  end

  defp confirm(meeting, status) do
    with {:ok, confirmed} <- MeetingQueries.update_meeting_status(meeting, status),
         {:ok, _job_status} <- PaymentCompletion.schedule_calendar_creation(confirmed),
         {:ok, pending} <-
           Activation.activate_in_transaction(confirmed,
             announce: :series,
             with_video_room: true
           ) do
      {:ok, confirmed, pending}
    end
  end

  # The series is taken whole: every session awaiting payment, or, for a
  # payment that failed meanwhile, every session expired. A series some of
  # whose sessions were released while the rest waited for the payment
  # cannot be confirmed as booked, and must not keep the rest held and the
  # money pending for ever: it is refused, the held sessions released and
  # the payment refunded. (Cancelling one held session is refused
  # (`Bookings.Policy`), so this is the defence, not the expected path.)
  defp check_transition(meetings, payment) do
    {held, others} = Enum.split_with(meetings, &MeetingState.awaiting_payment?/1)

    cond do
      others == [] ->
        {:proceed, :advanced}

      payment.status == :failed and Enum.all?(meetings, &MeetingState.expired?/1) ->
        {:proceed, :recovered}

      held != [] and Enum.all?(others, &MeetingState.released_status?(&1.status)) ->
        {:refuse, :sessions_released}

      true ->
        :no_op
    end
  end

  defp slot_checked(:recovered, :unchecked), do: {:error, :slot_unchecked}
  defp slot_checked(_transition, _slot), do: :ok

  # Recorded paid, as it truly was, every session still held expired (one
  # already released keeps its status), and the whole payment refunded by a
  # job inserted in this transaction.
  defp refuse(payment, meetings, event_id, object) do
    with {:ok, paid} <- PaymentCompletion.mark_paid(payment, event_id, object),
         {:ok, [first | _rest]} <- expire_all(meetings),
         {:ok, _job} <- Oban.insert(RefundLatePayment.new_for(paid.id)) do
      {:ok, {:refused, paid, first}}
    end
  end

  # The series has no session left (its host's account was deleted), so a
  # payment still awaiting its money is recorded paid and refunded in full.
  defp refund_orphaned(%{status: status} = payment, event_id, object)
       when status in [:pending, :failed] do
    with {:ok, paid} <- PaymentCompletion.mark_paid(payment, event_id, object),
         {:ok, _job} <- Oban.insert(RefundLatePayment.new_for(paid.id)) do
      {:ok, {:refused, paid, nil}}
    end
  end

  defp refund_orphaned(_payment, _event_id, _object), do: {:ok, :no_op}

  defp expire_all(meetings) do
    result =
      Enum.reduce_while(meetings, {:ok, []}, fn meeting, {:ok, done} ->
        case expire(meeting) do
          {:ok, expired} -> {:cont, {:ok, [expired | done]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, done} <- result, do: {:ok, Enum.reverse(done)}
  end

  defp expire(%{status: :awaiting_payment} = meeting),
    do: MeetingQueries.update_meeting_status(meeting, %{status: :expired})

  defp expire(meeting), do: {:ok, meeting}

  # A slot of the series was taken since the expiry released it: the
  # sessions stay expired and the whole payment goes back, by a job, as for
  # a single late payment (`CheckoutSessionCompleted`).
  defp refund_late_payment(payment, event_id, object) do
    PaymentCompletion.backfill_charge_id(payment, object)

    LockedPayment.run(payment, event_id, fn locked ->
      {_series, meetings} = HeldMeetings.lock_series(locked.series_id)

      with [first | _rest] <- meetings,
           {:proceed, :recovered} <- check_transition(meetings, locked),
           {:ok, paid} <- PaymentCompletion.mark_paid(locked, event_id, object),
           {:ok, _job} <- Oban.insert(RefundLatePayment.new_for(paid.id)) do
        {:ok, {:refund_scheduled, paid, first}}
      else
        {:error, _reason} = error -> error
        _no_longer_recoverable -> {:ok, :no_op}
      end
    end)
  end
end
