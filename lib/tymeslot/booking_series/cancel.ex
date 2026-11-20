defmodule Tymeslot.BookingSeries.Cancel do
  @moduledoc """
  "Cancel all remaining": every session of a series still to come called off
  at once, by its booker (`caller: :attendee`) or its host
  (`caller: :organizer`), with one series cancellation email to each side
  in place of one per session, and one `meeting.series_cancelled` to the
  host's automations in place of a `meeting.cancelled` per session
  (`Tymeslot.BookingSeries.Automation`).

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

  A host cancelling a paid series refunds its one payment once: by default
  the remaining sessions' share (`unit_price_cents` for each session
  cancelled, capped at what remains). The refund is a job
  (`Tymeslot.MeetingPayments.Workers.SeriesHostRefund`) inserted in the
  transaction that cancels the sessions, so it is recorded with them and
  its Stripe call never runs inside that transaction. The job re-checks the
  payment under its row lock; a refund it cannot make is recorded as an
  error (and so alerted on), and the money stays on the payment for the
  host to refund by hand (see the worker for what the host is shown). A booker's cancellation
  never refunds.

  Takes the organiser's schedule lock, then the series row, then its
  sessions, as every writer of a series does, and cancels inside that
  transaction, so two cancel-alls (or one and a single cancel) never
  cancel, email or refund a session twice: the second finds
  `:nothing_to_cancel`.

  The series is closed (`cancelled_at`) once nothing of it is left to come:
  cancelled whole, its sessions cancelled one at a time (`maybe_close/1`),
  or its request released (`close_in_transaction/1`).
  """

  require Logger

  alias Tymeslot.Auth.UserSchema, as: User
  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Cancel, as: CancelMeeting
  alias Tymeslot.Bookings.CancelSeat
  alias Tymeslot.BookingSeries.Approval
  alias Tymeslot.BookingSeries.Automation
  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.Workers.SeriesHostRefund
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo

  @type occurrence :: Meeting.t() | Participant.t()
  @type refund_choice :: :none | :remaining | {:amount, pos_integer()}
  @type refund_refusal :: :not_paid | :outside_refund_window | :under_dispute

  @typedoc """
  What became of the refund: none asked for or owed (`:none`), a refund
  job inserted for `cents` (`{:scheduled, cents}`), the default refund
  left unmade because the payment cannot be refunded
  (`{:not_refunded, reason}`), or, for a withdrawn series request, what
  the withdrawal refunded (`{:refunded, cents}`).
  """
  @type refund_outcome ::
          :none
          | {:scheduled, pos_integer()}
          | {:not_refunded, refund_refusal()}
          | {:refunded, pos_integer()}

  @type result ::
          {:ok, %{cancelled: [occurrence()], refund: refund_outcome()}}
          | {:error,
             :nothing_to_cancel
             | :not_found
             | :exceeds_remaining
             | :invalid_amount
             | refund_refusal()
             | term()}

  @doc """
  Cancels every remaining session of `series` (see the module docs).

  Options:

    * `:caller` (required) - `:attendee` or `:organizer`.
    * `:acting_user` - the organiser, who must own the series; anyone else,
      or none, gets `{:error, :not_found}` before anything is touched.
    * `:refund` - the organiser's refund of a paid series: `:remaining`
      (the default), `{:amount, cents}` or `:none`. Ignored for an
      attendee, whose cancellation never refunds, and for a series request,
      which is refunded in full when withdrawn.
    * `:expect` - `:withdraw` when the caller means to withdraw an open
      request and nothing else: a series that is no request any more (the
      host answered meanwhile) is then left alone and
      `{:error, :not_awaiting_approval}` returned, rather than its sessions
      cancelled. Without it, what is left of an answered request is
      cancelled as any series is.

  An explicit `{:amount, cents}` is refused before anything is cancelled
  when it cannot be made: `:invalid_amount` for one that is not a positive
  integer, `:exceeds_remaining` for one above what remains, and the
  payment's refusal (`:not_paid`, also for a series with no payment,
  `:outside_refund_window`, `:under_dispute`). The default `:remaining`
  on a payment that cannot be refunded cancels without a refund and says
  why (`refund: {:not_refunded, reason}`).
  """
  @spec cancel_remaining(SeriesSchema.t(), keyword()) :: result()
  def cancel_remaining(%SeriesSchema{} = series, opts) do
    caller = Keyword.fetch!(opts, :caller)

    withdraw_only? = Keyword.get(opts, :expect) == :withdraw

    with {:ok, refund_plan} <- authorise(series, caller, opts) do
      cond do
        series_request?(series) -> withdraw_request(series, caller, refund_plan, withdraw_only?)
        withdraw_only? -> {:error, :not_awaiting_approval}
        true -> cancel_all(series, caller, refund_plan)
      end
    end
  end

  @doc """
  Closes `series` (stamps `cancelled_at`) when nothing of it is left to
  come, after one of its sessions was cancelled on its own. Does nothing to
  a series already closed, one with a session still to come, or one that
  is gone.

  Runs in a transaction of its own and is called outside any: a failure is
  logged and never fails the cancellation that called it. Inside a
  transaction, call `close_in_transaction/1` instead, whose failure is the
  transaction's.
  """
  @spec maybe_close(SeriesSchema.t() | binary()) :: :ok
  def maybe_close(%SeriesSchema{id: id}), do: maybe_close(id)

  def maybe_close(series_id) when is_binary(series_id) do
    {:ok, :ok} = Repo.transaction(fn -> close_in_transaction(series_id) end)
    :ok
  rescue
    exception ->
      Logger.error("Failed to close a series after a cancellation",
        series_id: series_id,
        reason: LogFormat.reason(exception)
      )

      :ok
  end

  @doc """
  `maybe_close/1` inside the caller's transaction: locks the series row
  (after the schedule lock, before any session, as every writer of a
  series does), re-reads it, and closes it when nothing of it is left to
  come. Raises on a failed write, for the caller's transaction to roll
  back.
  """
  @spec close_in_transaction(binary()) :: :ok
  def close_in_transaction(series_id) when is_binary(series_id) do
    now = Clock.utc_now()

    with %SeriesSchema{cancelled_at: nil} = series <- SeriesQueries.lock(series_id),
         false <- series |> SeriesQueries.list_occurrences() |> Enum.any?(&remaining?(&1, now)) do
      {:ok, _closed} = SeriesQueries.mark_cancelled(series, now)
    end

    :ok
  end

  # Ownership, and the refund the host's choice implies, are settled before
  # anything is cancelled: a refusal must not leave cancelled sessions.
  defp authorise(_series, :attendee, _opts), do: {:ok, :none}

  defp authorise(series, :organizer, opts) do
    with :ok <- owned_by(series, Keyword.get(opts, :acting_user)) do
      series.id
      |> MeetingPayments.payment_for_series()
      |> plan_refund(Keyword.get(opts, :refund, :remaining))
    end
  end

  defp owned_by(%SeriesSchema{organizer_user_id: owner_id}, %User{id: owner_id}), do: :ok
  defp owned_by(_series, _user), do: {:error, :not_found}

  defp plan_refund(_payment, :none), do: {:ok, :none}
  defp plan_refund(nil, :remaining), do: {:ok, :none}

  defp plan_refund(payment, :remaining) do
    case MeetingPayments.refund_refusal(payment) do
      :ok -> {:ok, {:remaining, payment}}
      {:error, reason} -> {:ok, {:not_refunded, reason}}
    end
  end

  defp plan_refund(payment, {:amount, cents}) when is_integer(cents) and cents > 0 do
    with :ok <- refusal(payment),
         :ok <- within_remaining(payment, cents) do
      {:ok, {:amount, payment, cents}}
    end
  end

  defp plan_refund(_payment, _choice), do: {:error, :invalid_amount}

  defp refusal(nil), do: {:error, :not_paid}
  defp refusal(payment), do: MeetingPayments.refund_refusal(payment)

  defp within_remaining(payment, cents) do
    if MeetingPayments.refund_outstanding?(payment) and
         cents <= MeetingPayments.refundable_remaining_cents(payment),
       do: :ok,
       else: {:error, :exceeds_remaining}
  end

  # Series request

  @doc """
  Whether `series` is still an open approval request, which
  `cancel_remaining/2` withdraws whole rather than cancelling session by
  session (`Tymeslot.BookingSeries.Approval.series_request?/1`).
  """
  @spec open_request?(SeriesSchema.t()) :: boolean()
  def open_request?(%SeriesSchema{} = series), do: series_request?(series)

  defp series_request?(series) do
    case series
         |> SeriesQueries.list_meetings()
         |> Enum.find(&MeetingState.awaiting_approval?/1) do
      nil -> false
      held -> Approval.series_request?(held)
    end
  end

  # Withdrawn whole, refunded whole and closed by the withdrawal itself. A
  # request the host answered meanwhile is no request any more: what is
  # left of it is cancelled as any series is, unless the caller meant a
  # withdrawal only, who is told so instead (an approved, paid series must
  # never be cancelled without a refund by a click meant to withdraw).
  defp withdraw_request(series, caller, refund_plan, withdraw_only?) do
    refunded_before = refunded_cents(series)

    case Approval.withdraw(series, caller) do
      {:ok, released} ->
        {:ok, %{cancelled: released, refund: refund_since(series, refunded_before)}}

      {:error, :not_awaiting_approval} = answered when withdraw_only? ->
        answered

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

  defp cancel_all(series, caller, refund_plan) do
    case Repo.transaction(fn -> cancel_in_transaction(series, caller, refund_plan) end) do
      {:ok, {cancelled, refund}} ->
        Logger.info("Series cancelled", series_id: series.id, sessions: length(cancelled))
        after_commit(cancelled)
        {:ok, %{cancelled: occurrences(cancelled), refund: refund}}

      {:error, reason} = error ->
        Logger.info("Series not cancelled",
          series_id: series.id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  defp cancel_in_transaction(series, caller, refund_plan) do
    :ok = MeetingConflictQueries.lock_organizer_schedule(series.organizer_user_id)
    locked = SeriesQueries.lock(series) || Repo.rollback(:not_found)
    now = Clock.utc_now()

    cancelled =
      locked
      |> locked_occurrences()
      |> Enum.filter(&cancellable?(&1, now))
      |> Enum.map(&cancel_occurrence(&1, caller))

    if cancelled == [], do: Repo.rollback(:nothing_to_cancel)

    :ok = close_in_transaction(locked.id)

    cancelled_occurrences = occurrences(cancelled)

    with {:ok, _job} <-
           Notifications.schedule_series_cancellation(locked, cancelled_occurrences, caller),
         {:ok, _job} <- schedule_automation(locked, cancelled_occurrences),
         {:ok, refund} <- schedule_refund(locked, cancelled, refund_plan) do
      {cancelled, refund}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # One `meeting.series_cancelled` for the host's automations, in place of
  # a `meeting.cancelled` per session (`after_commit/1`).
  defp schedule_automation(series, cancelled) do
    series
    |> Automation.cancelled_job(Enum.map(cancelled, & &1.id))
    |> Oban.insert()
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

  # The series is closed once, by `cancel_in_transaction/3`, not by each
  # session's cancellation.
  defp cancel_occurrence(%Meeting{} = meeting, caller) do
    case CancelMeeting.execute(meeting, caller: caller, announce: false, close_series: false) do
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

  # The series' own email tells both sides, and its own event the host's
  # automations; everything else a cancellation does follows each session
  # as usual.
  @told_with_series [emails: false, integrations: false]

  defp after_commit([%Meeting{organizer_user_id: organizer_id} | _rest] = meetings) do
    Availability.changed(organizer_id)
    Enum.each(meetings, &Events.meeting_cancelled(&1, @told_with_series))
  end

  defp after_commit(released_seats),
    do: Enum.each(released_seats, &CancelSeat.finish(&1, @told_with_series))

  # Refund

  defp schedule_refund(_series, _cancelled, :none), do: {:ok, :none}

  defp schedule_refund(_series, _cancelled, {:not_refunded, _reason} = outcome),
    do: {:ok, outcome}

  # The remaining sessions' share, read in this transaction; the job reads
  # the payment again under its lock and refuses more than remains then.
  defp schedule_refund(series, cancelled, {:remaining, payment}) do
    case MeetingPayments.get_payment(payment.id) do
      nil ->
        {:ok, :none}

      current ->
        share = remaining_share_cents(series, current, length(cancelled))

        if share > 0 and MeetingPayments.refund_outstanding?(current),
          do: insert_refund(series, current, share),
          else: {:ok, :none}
    end
  end

  defp schedule_refund(series, _cancelled, {:amount, payment, cents}),
    do: insert_refund(series, MeetingPayments.get_payment(payment.id) || payment, cents)

  @doc """
  The host's default refund for cancelling `count` sessions of a paid
  `series`: one session's price for each, never more than `payment` has
  left to refund. What `cancel_remaining/2` refunds with `refund:
  :remaining`, so the dashboard can say the amount before the host confirms.
  """
  @spec remaining_share_cents(SeriesSchema.t(), map(), non_neg_integer()) :: non_neg_integer()
  def remaining_share_cents(%SeriesSchema{unit_price_cents: price}, payment, count)
      when is_integer(price) and is_integer(count),
      do: min(price * count, MeetingPayments.refundable_remaining_cents(payment))

  def remaining_share_cents(%SeriesSchema{}, _payment, _count), do: 0

  @doc """
  The `:refund` option the host's choice in a cancellation form (the
  `cancel_refund_choice` the single cancel dialog also posts) implies:
  `"partial"` an explicit `{:amount, cents}` read from
  `cancel_refund_amount`, `"none"` no refund once acknowledged
  (`cancel_refund_no_refund_ack`), anything else the remaining sessions'
  share. Refused as the single cancellation's choice is
  (`:acknowledgement_required`, `:exceeds_remaining`, `:invalid_amount`).
  """
  @spec resolve_refund_choice(map() | nil, map()) ::
          {:ok, refund_choice()}
          | {:error, :acknowledgement_required | :exceeds_remaining | :invalid_amount}
  def resolve_refund_choice(payment, %{"cancel_refund_choice" => choice} = params)
      when choice in ["partial", "none"] do
    case Meetings.resolve_cancellation_refund(payment, params) do
      {:ok, {:refund, cents}} -> {:ok, {:amount, cents}}
      {:ok, :none} -> {:ok, :none}
      {:error, _reason} = error -> error
    end
  end

  def resolve_refund_choice(_payment, _params), do: {:ok, :remaining}

  defp insert_refund(series, payment, cents) do
    with {:ok, _job} <-
           payment
           |> SeriesHostRefund.new_for(series.organizer_user_id, cents)
           |> Oban.insert() do
      {:ok, {:scheduled, cents}}
    end
  end

  # Remaining

  @doc """
  Whether `cancel_remaining/2` cancels `occurrence` (a meeting, or a seat
  with its meeting preloaded) when the series is not an open request: it
  is live and still to start, and not held for the series' checkout,
  which releases it itself. A session held for approval on its own, after
  a reschedule, is cancelled with the rest.
  """
  @spec cancellable?(occurrence(), DateTime.t()) :: boolean()
  def cancellable?(occurrence, now),
    do: remaining?(occurrence, now) and not held_for_payment?(occurrence)

  defp remaining?(%Meeting{} = meeting, now),
    do: not MeetingState.terminal?(meeting) and upcoming?(meeting, now)

  defp remaining?(%Participant{meeting: meeting} = seat, now),
    do: Participant.live?(seat) and remaining?(meeting, now)

  defp upcoming?(%Meeting{start_time: start_time}, now),
    do: DateTime.compare(start_time, now) == :gt

  defp held_for_payment?(%Meeting{} = meeting), do: MeetingState.awaiting_payment?(meeting)
  defp held_for_payment?(%Participant{}), do: false
end
