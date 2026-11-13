defmodule Tymeslot.BookingSeries.Cancel do
  @moduledoc """
  "Cancel all remaining": every session of a series still to come called off
  at once, by its booker (`caller: :attendee`) or its host
  (`caller: :organizer`), with one series cancellation email to each side
  in place of one per session.

  A session is remaining when it has not started and is still live: a
  meeting in no terminal status, or a seat not given up on a session not
  cancelled. Sessions under way or over are left as they are.

  Each remaining one-to-one session goes through `Tymeslot.Bookings.Cancel`
  with its announcement held back (calendar event removed, video room
  deleted, as for any cancellation), then its reminders are cancelled and
  integrations told once the cancellation has committed. Each remaining
  seat goes through `Tymeslot.Bookings.CancelSeat`'s transactional half, so
  a session the series was alone in is cancelled with it and one with
  other seats stays.

  Two states are not cancelled here:

    * an open series approval request is withdrawn whole through
      `Tymeslot.BookingSeries.Approval.withdraw/3`, which releases every
      session, refunds a paid series in full once and sends its own email;
    * sessions held `awaiting_payment` are left to their checkout, which
      releases them whole when it expires. A series with nothing else left
      has `:nothing_to_cancel`.

  A host cancelling a paid series refunds its one payment once, after the
  sessions are cancelled and outside any transaction: by default the
  remaining sessions' share (`unit_price_cents` for each session
  cancelled, capped at what remains). A booker's cancellation never
  refunds.

  Takes the organiser's schedule lock, then the series row, then its
  sessions, as every writer of a series does, and cancels inside that
  transaction, so two cancel-alls (or one and a single cancel) never
  cancel, email or refund a session twice: the second finds
  `:nothing_to_cancel`.

  The series is closed (`cancelled_at`) once nothing of it is left to come,
  whether by cancelling it whole or its sessions one at a time
  (`maybe_close/1`).
  """

  require Logger

  alias Tymeslot.Auth.UserSchema, as: User
  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Cancel, as: CancelMeeting
  alias Tymeslot.Bookings.CancelSeat
  alias Tymeslot.BookingSeries.Approval
  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo

  @type occurrence :: Meeting.t() | Participant.t()
  @type refund_choice :: :none | :remaining | {:amount, pos_integer()}
  @type refund_outcome :: :none | {:refunded, non_neg_integer()}

  @type result ::
          {:ok, %{cancelled: [occurrence()], refund: refund_outcome()}}
          | {:error,
             :nothing_to_cancel
             | :not_found
             | :exceeds_remaining
             | :invalid_amount
             | {:refund_failed, term()}
             | term()}

  @doc """
  Cancels every remaining session of `series` (see the module docs).

  Options:

    * `:caller` (required) - `:attendee` or `:organizer`.
    * `:acting_user` - the organiser, who must own the series; anyone else,
      or none, gets `{:error, :not_found}` before anything is touched.
    * `:refund` - the organiser's refund of a paid series: `:remaining`
      (the default), `{:amount, cents}` or `:none`. An amount that is not
      a positive integer is `:invalid_amount`, one above what remains
      `:exceeds_remaining`, both refused before anything is cancelled.
      Ignored for an attendee, whose cancellation never refunds, and for a
      series request, which is refunded in full when withdrawn.

  `{:error, {:refund_failed, reason}}` reports a refund that failed after
  the sessions were cancelled; they stay cancelled, and the host can
  settle the refund from Stripe.
  """
  @spec cancel_remaining(SeriesSchema.t(), keyword()) :: result()
  def cancel_remaining(%SeriesSchema{} = series, opts) do
    caller = Keyword.fetch!(opts, :caller)

    with {:ok, refund_plan} <- authorise(series, caller, opts) do
      if series_request?(series) do
        withdraw_request(series, caller, refund_plan)
      else
        cancel_all(series, caller, refund_plan)
      end
    end
  end

  @doc """
  Closes `series` (stamps `cancelled_at`) when nothing of it is left to
  come, after one of its sessions was cancelled. Does nothing to a series
  already closed, one with a session still to come, or one that is gone.
  Never fails the cancellation that called it.
  """
  @spec maybe_close(SeriesSchema.t() | binary()) :: :ok
  def maybe_close(%SeriesSchema{id: id}), do: maybe_close(id)

  def maybe_close(series_id) when is_binary(series_id) do
    {:ok, :ok} = Repo.transaction(fn -> close(series_id, Clock.utc_now()) end)
    :ok
  rescue
    exception ->
      Logger.error("Failed to close a series after a cancellation",
        series_id: series_id,
        reason: LogFormat.reason(exception)
      )

      :ok
  end

  # Ownership, and the refund the host's choice implies, are settled before
  # anything is cancelled: a refusal must not leave cancelled sessions.
  defp authorise(_series, :attendee, _opts), do: {:ok, :none}

  defp authorise(series, :organizer, opts) do
    with :ok <- owned_by(series, Keyword.get(opts, :acting_user)) do
      plan_refund(series, Keyword.get(opts, :refund, :remaining))
    end
  end

  defp owned_by(%SeriesSchema{organizer_user_id: owner_id}, %User{id: owner_id}), do: :ok

  defp owned_by(_series, _user), do: {:error, :not_found}

  defp plan_refund(_series, :none), do: {:ok, :none}

  defp plan_refund(series, choice) do
    case MeetingPayments.payment_for_series(series.id) do
      nil -> {:ok, :none}
      payment -> validate_refund(payment, choice)
    end
  end

  defp validate_refund(payment, :remaining), do: {:ok, {:remaining, payment}}

  defp validate_refund(payment, {:amount, cents}) when is_integer(cents) and cents > 0 do
    if MeetingPayments.refund_outstanding?(payment) and
         cents <= MeetingPayments.refundable_remaining_cents(payment),
       do: {:ok, {:amount, payment, cents}},
       else: {:error, :exceeds_remaining}
  end

  defp validate_refund(_payment, _choice), do: {:error, :invalid_amount}

  # Series request

  defp series_request?(series) do
    case series
         |> SeriesQueries.list_meetings()
         |> Enum.find(&MeetingState.awaiting_approval?/1) do
      nil -> false
      held -> Approval.series_request?(held)
    end
  end

  # Withdrawn whole, refunded whole by the withdrawal itself. A request the
  # host answered meanwhile is no request any more: what is left of it is
  # cancelled as any series is.
  defp withdraw_request(series, caller, refund_plan) do
    refunded_before = refunded_cents(series)

    case Approval.withdraw(series, caller) do
      {:ok, released} ->
        maybe_close(series)
        {:ok, %{cancelled: released, refund: refund_since(series, refunded_before)}}

      {:error, :not_awaiting_approval} ->
        cancel_all(series, caller, refund_plan)

      {:error, _reason} = error ->
        error
    end
  end

  defp refunded_cents(series) do
    case MeetingPayments.payment_for_series(series.id) do
      nil -> 0
      payment -> payment.refunded_amount_cents
    end
  end

  defp refund_since(series, before) do
    case refunded_cents(series) - before do
      refunded when refunded > 0 -> {:refunded, refunded}
      _none -> :none
    end
  end

  # Cancel all

  defp cancel_all(series, caller, refund_plan) do
    case Repo.transaction(fn -> cancel_in_transaction(series, caller) end) do
      {:ok, {locked, cancelled}} ->
        Logger.info("Series cancelled", series_id: series.id, sessions: length(cancelled))
        after_commit(cancelled)
        refund(locked, cancelled, refund_plan)

      {:error, reason} = error ->
        Logger.info("Series not cancelled",
          series_id: series.id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  defp cancel_in_transaction(series, caller) do
    now = Clock.utc_now()
    :ok = MeetingConflictQueries.lock_organizer_schedule(series.organizer_user_id)
    locked = SeriesQueries.lock(series) || Repo.rollback(:not_found)

    cancelled =
      locked
      |> locked_occurrences()
      |> Enum.filter(&remaining?(&1, now))
      |> Enum.reject(&held_for_payment?/1)
      |> Enum.map(&cancel_occurrence(&1, caller))

    if cancelled == [], do: Repo.rollback(:nothing_to_cancel)

    close(locked.id, now)

    case Notifications.schedule_series_cancellation(locked, occurrences(cancelled), caller) do
      {:ok, _job} -> {locked, cancelled}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A one-to-one series' sessions are locked in series order, after the
  # series; a group series' seats are locked with their session, one by one,
  # as each is given up.
  defp locked_occurrences(series) do
    case SeriesQueries.lock_meetings(series) do
      [] -> SeriesQueries.list_occurrences(series)
      meetings -> meetings
    end
  end

  defp cancel_occurrence(%Meeting{} = meeting, caller) do
    case CancelMeeting.execute(meeting, caller: caller, announce: false) do
      {:ok, cancelled} -> cancelled
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp cancel_occurrence(%Participant{} = seat, _caller) do
    case CancelSeat.cancel_in_transaction(seat) do
      {:ok, released} -> released
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp occurrences(cancelled), do: Enum.map(cancelled, &occurrence/1)

  defp occurrence(%{participant: %Participant{} = seat}), do: seat
  defp occurrence(%Meeting{} = meeting), do: meeting

  # The series' own email tells both sides; everything else a cancellation
  # does follows each session as usual.
  defp after_commit([%Meeting{organizer_user_id: organizer_id} | _rest] = meetings) do
    Availability.changed(organizer_id)
    Enum.each(meetings, &Events.meeting_cancelled(&1, emails: false))
  end

  defp after_commit(released_seats),
    do: Enum.each(released_seats, &CancelSeat.finish(&1, emails: false))

  # Refund

  defp refund(_series, cancelled, :none), do: ok(cancelled, :none)

  defp refund(series, cancelled, {:remaining, payment}) do
    payment = MeetingPayments.get_payment(payment.id)

    share =
      min(
        (series.unit_price_cents || 0) * length(cancelled),
        MeetingPayments.refundable_remaining_cents(payment)
      )

    if share > 0 and MeetingPayments.refund_outstanding?(payment),
      do: issue_refund(series, cancelled, payment, share),
      else: ok(cancelled, :none)
  end

  defp refund(series, cancelled, {:amount, payment, cents}),
    do: issue_refund(series, cancelled, payment, cents)

  defp issue_refund(series, cancelled, payment, cents) do
    case MeetingPayments.refund_payment_for_host(payment.id, series.organizer_user_id, cents) do
      {:ok, _payment} ->
        ok(cancelled, {:refunded, cents})

      {:error, reason} ->
        Logger.error("Series cancelled, but its refund failed",
          series_id: series.id,
          reason: LogFormat.reason(reason)
        )

        {:error, {:refund_failed, reason}}
    end
  end

  defp ok(cancelled, refund), do: {:ok, %{cancelled: occurrences(cancelled), refund: refund}}

  # Remaining

  # Under the series row lock, re-read: a session cancelled in the same
  # transaction may have closed it already.
  defp close(series_id, now) do
    with %SeriesSchema{cancelled_at: nil} = series <- SeriesQueries.lock(series_id),
         false <- series |> SeriesQueries.list_occurrences() |> Enum.any?(&remaining?(&1, now)) do
      {:ok, _closed} = SeriesQueries.mark_cancelled(series, now)
    end

    :ok
  end

  defp remaining?(%Meeting{} = meeting, now),
    do: not MeetingState.terminal?(meeting) and upcoming?(meeting, now)

  defp remaining?(%Participant{meeting: meeting} = seat, now),
    do: Participant.live?(seat) and remaining?(meeting, now)

  defp upcoming?(%Meeting{start_time: start_time}, now),
    do: DateTime.compare(start_time, now) == :gt

  defp held_for_payment?(%Meeting{} = meeting), do: MeetingState.awaiting_payment?(meeting)
  defp held_for_payment?(%Participant{}), do: false
end
