defmodule Tymeslot.BookingSeries.Approval do
  @moduledoc """
  The approval gate for a booking series: one request, one answer.

  A series booked on a type requiring approval holds every session
  `awaiting_approval`, all with the first session's deadline
  (`Tymeslot.Bookings.MeetingAttributes.share_series_approval_clock/1`), and
  is requested once (`Tymeslot.BookingSeries.Notifications.schedule_series_request/1`).
  The host answers for the series as a whole, never for a session:

    * `approve/2` confirms every session still held, each through the
      ordinary confirmation pipeline (calendar event, reminders, video room)
      as a session of a series, and sends the series' one confirmation.
    * `decline/3`, `expire/1` and `withdraw/3` release every session still
      held, refund a paid series' one payment in full, once, and send one
      email: the booker's decline or expiry notice, or for a withdrawal the
      series cancellation to both. The series is closed with its sessions
      when nothing of it is left to come
      (`Tymeslot.BookingSeries.Cancel.close_in_transaction/1`).

  Each takes the organiser's schedule lock, then the series row, then its
  sessions in series order, as every writer of a series does, and moves
  every session still held through the guarded
  `MeetingTransitionQueries.transition_from_awaiting_approval/2` in one transaction.
  A session that cannot be moved rolls back the series, so it is never left
  half approved. Nothing external happens inside the transaction: the
  calendar, video, refund and email work runs once it has committed, each
  step best-effort, in the order `Tymeslot.Meetings.Approval` uses for a
  single request.

  Only an open series request is answered here (`series_request?/1`): a
  confirmed session moved back into the gate on its own is a single
  request, answered by `Tymeslot.Meetings.Approval` with its own emails,
  and the rest of its series stays booked.

  The single-request entry points (`Tymeslot.Meetings.Approval.approve/1`,
  `decline/2`, `expire/1`, `withdraw/2`) hand a session of an open series
  request here through `for_session/2`, so the dashboard's request card, the host's email
  links, the expiry job and the sweep all answer the whole series. That
  includes the host deleting one session's tentative event from their own
  calendar (`Tymeslot.Bookings.Cancel`): it withdraws the whole series, as a
  series missing a session is not the series that was asked for.
  """

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema, as: User
  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.BookingSeries.Automation
  alias Tymeslot.BookingSeries.Cancel, as: SeriesCancel
  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.Approval, as: MeetingApproval
  alias Tymeslot.Meetings.ApprovalRefunds
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Notifications.DispatchInTransactionError
  alias Tymeslot.Repo

  @typedoc """
  Who withdrew a series request: its booker, the host's own calendar, or
  the host calling the whole series off (`Tymeslot.BookingSeries.Cancel`).
  """
  @type withdrawn_by :: :attendee | :calendar | :organizer

  @typedoc "An answer a single-request entry point asks of a session's series."
  @type session_action ::
          :approve
          | {:decline, String.t() | nil}
          | :expire
          | {:withdraw, withdrawn_by(), keyword()}

  @doc """
  Approves the series: every session still held is confirmed and joins the
  booking pipeline, and the series' one confirmation is scheduled, all in
  one transaction.

  Refused with `:not_awaiting_approval` when no session is held any more
  (the series was answered or withdrawn first), and `:past_deadline` when
  the shared deadline has passed, in which case the series is released as
  expired, exactly as the expiry job would have. `:slot_taken` when a slot
  was taken meanwhile, leaving the series held; `:not_scheduled` when the
  confirmation could not be queued, rolling the approval back.
  `{:error, :not_found}` for an actor who is not the series' organiser.
  """
  @spec approve(SeriesSchema.t(), User.t()) ::
          {:ok, [Meeting.t()]}
          | {:error, :not_awaiting_approval | :past_deadline | :not_found | term()}
  def approve(%SeriesSchema{} = series, %User{} = actor) do
    with :ok <- owned_by(series, actor) do
      series
      |> confirm(Clock.utc_now())
      |> settle_approval(series)
    end
  end

  @doc """
  Declines the series: every session still held is cancelled and released,
  a paid series refunded in full, and the booker told once, with the host's
  `reason` when given (trimmed and capped as for a single request).
  `{:error, :not_found}` for an actor who is not the series' organiser.
  """
  @spec decline(SeriesSchema.t(), User.t(), String.t() | nil) ::
          {:ok, [Meeting.t()]} | {:error, term()}
  def decline(%SeriesSchema{} = series, %User{} = actor, reason \\ nil) do
    with :ok <- owned_by(series, actor) do
      now = DateTime.truncate(Clock.utc_now(), :second)

      changes =
        [status: :cancelled, approval_resolved_at: now, cancelled_at: now] ++
          MeetingApproval.decline_changes(reason, now)

      release(series, changes, &announce_outcome(series, &1, :declined))
    end
  end

  @doc """
  Releases a series nobody answered before its deadline: every session
  still held becomes `:expired`, a paid series is refunded in full, and the
  booker is told once. For the expiry job and the sweep.
  """
  @spec expire(SeriesSchema.t()) :: {:ok, [Meeting.t()]} | {:error, term()}
  def expire(%SeriesSchema{} = series) do
    now = DateTime.truncate(Clock.utc_now(), :second)
    changes = [status: :expired, approval_resolved_at: now, cancelled_at: now]

    release(series, changes, &announce_outcome(series, &1, :expired))
  end

  @doc """
  Withdraws a series request outside of the host's decision: its booker
  changed their mind (`:attendee`), the host deleted a session's
  tentative event from their own calendar (`:calendar`), or the host
  cancelled the series as a whole (`:organizer`). Every session
  still held is cancelled and released, a paid series refunded in full,
  and both sides sent one series cancellation, worded as the booker's or
  the host's. Neither `approval_resolved_at` nor `approval_declined_at` is
  set, as for a single withdrawal. `extra_changes` are written to every
  session (`Bookings.Cancel`'s reason for an external deletion).
  """
  @spec withdraw(SeriesSchema.t(), withdrawn_by(), keyword()) ::
          {:ok, [Meeting.t()]} | {:error, term()}
  def withdraw(%SeriesSchema{} = series, withdrawn_by, extra_changes \\ [])
      when withdrawn_by in [:attendee, :calendar, :organizer] do
    now = DateTime.truncate(Clock.utc_now(), :second)
    changes = [status: :cancelled, cancelled_at: now] ++ extra_changes

    release(series, changes, &announce_withdrawal(series, &1, withdrawn_by))
  end

  @doc """
  Answers a single-request call on a session of a series by answering the
  series, returning the session as it now is (`:not_in_series` for a
  meeting outside any series, or whose series is gone). The single entry
  points take no actor, their callers having established it is the host, so
  the series' own organiser answers. A series past its deadline is reported
  as `:not_awaiting_approval`, as a single request is.
  """
  @spec for_session(Meeting.t(), session_action()) ::
          {:ok, Meeting.t()} | {:error, term()} | :not_in_series
  def for_session(%Meeting{} = meeting, action) do
    with true <- series_request?(meeting),
         {:ok, series} <- SeriesQueries.get(meeting.series_id) do
      series |> answer(action) |> as_session(meeting)
    else
      _single_or_gone -> :not_in_series
    end
  end

  @doc """
  Whether `meeting` is one session of a series request still open: it is
  held for approval, and so is every session of its series not yet over,
  all on the series' one request (the same `approval_requested_at`) and
  none of them a booking confirmed before. A confirmed session the booker
  moved back into the gate is not: it is a request of its own, answered
  as any rescheduled booking is, and the rest of its series stays booked.
  """
  @spec series_request?(Meeting.t()) :: boolean()
  def series_request?(%Meeting{status: :awaiting_approval, series_id: series_id} = meeting)
      when is_binary(series_id),
      do: request_sessions(meeting, SeriesQueries.list_meetings(series_id)) != nil

  def series_request?(_meeting), do: false

  @doc """
  The sessions an open series request holds, in series order, when
  `meeting` is one of them (`series_request?/1`), read from `sessions`, the
  meetings of its series already loaded; nil when it is not. For a caller
  that lists many meetings and loads their series' sessions in one go.
  """
  @spec request_sessions(Meeting.t(), [Meeting.t()]) :: [Meeting.t()] | nil
  def request_sessions(
        %Meeting{status: :awaiting_approval, series_id: series_id, id: id},
        sessions
      )
      when is_binary(series_id) do
    if Enum.any?(sessions, &(&1.id == id and MeetingState.awaiting_approval?(&1))) and
         open_request?(sessions),
       do: Enum.reject(sessions, &MeetingState.terminal?/1)
  end

  def request_sessions(_meeting, _sessions), do: nil

  defp open_request?(sessions) do
    case Enum.reject(sessions, &MeetingState.terminal?/1) do
      [] ->
        false

      [first | _rest] = live ->
        Enum.all?(live, fn session ->
          MeetingState.awaiting_approval?(session) and is_nil(session.first_announced_at) and
            session.approval_requested_at == first.approval_requested_at
        end)
    end
  end

  defp answer(series, :approve), do: as_organiser(series, &approve/2)
  defp answer(series, {:decline, reason}), do: as_organiser(series, &decline(&1, &2, reason))
  defp answer(series, :expire), do: expire(series)
  defp answer(series, {:withdraw, by, changes}), do: withdraw(series, by, changes)

  defp as_organiser(series, fun) do
    case Auth.get_user(series.organizer_user_id) do
      {:ok, organiser} -> fun.(series, organiser)
      {:error, :not_found} -> {:error, :not_awaiting_approval}
    end
  end

  defp as_session({:ok, sessions}, meeting) do
    case Enum.find(sessions, &(&1.id == meeting.id)) do
      nil -> {:error, :not_awaiting_approval}
      session -> {:ok, session}
    end
  end

  defp as_session({:error, :past_deadline}, _meeting), do: {:error, :not_awaiting_approval}
  defp as_session({:error, _reason} = error, _meeting), do: error

  defp owned_by(%SeriesSchema{organizer_user_id: owner_id}, %User{id: owner_id}), do: :ok
  defp owned_by(_series, _actor), do: {:error, :not_found}

  # Approval

  # The confirmations, their emails and reminders and the series'
  # confirmation commit together, as for a single approval.
  defp confirm(series, now) do
    Repo.transaction(fn ->
      held = lock_held(series)

      if MeetingState.approval_deadline_passed?(hd(held), now),
        do: Repo.rollback(:past_deadline)

      confirmed = Enum.map(held, &confirm_session(&1, now))

      case Notifications.schedule_series_confirmation(series) do
        {:ok, _job} -> confirmed
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp confirm_session(meeting, now) do
    with {:ok, confirmed} <-
           MeetingTransitionQueries.transition_from_awaiting_approval(meeting.id,
             status: :confirmed,
             approval_resolved_at: DateTime.truncate(now, :second)
           ),
         {:ok, pending} <-
           Activation.activate_in_transaction(confirmed,
             announce: :series,
             with_video_room: true
           ) do
      {confirmed, pending}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp settle_approval({:ok, confirmed}, series) do
    Logger.info("Series request approved", series_id: series.id, sessions: length(confirmed))
    Availability.changed(series.organizer_user_id)

    Enum.each(confirmed, fn {meeting, pending} ->
      MeetingApproval.activate_confirmed(meeting, pending)
    end)

    {:ok, Enum.map(confirmed, &elem(&1, 0))}
  end

  # The host answered after the window the booker was promised: the series
  # is released as the expiry job would have released it.
  defp settle_approval({:error, :past_deadline} = error, series) do
    Logger.info("Series approval refused: past its deadline", series_id: series.id)
    _released = expire(series)
    error
  end

  defp settle_approval({:error, reason} = error, series)
       when reason in [:not_awaiting_approval, :slot_taken, :not_found] do
    Logger.info("Series approval refused", series_id: series.id, reason: reason)
    error
  end

  defp settle_approval({:error, reason}, series) do
    Logger.error("Series approval rolled back: the confirmation could not be scheduled",
      series_id: series.id,
      reason: LogFormat.reason(reason)
    )

    {:error, :not_scheduled}
  end

  # Release

  defp release(series, changes, announce) do
    case Repo.transaction(fn -> release_in_transaction(series, changes) end) do
      {:ok, released} ->
        Logger.info("Series request released",
          series_id: series.id,
          status: hd(released).status,
          sessions: length(released)
        )

        Availability.changed(series.organizer_user_id)
        after_release(series, released, announce)
        {:ok, released}

      {:error, reason} = error ->
        Logger.info("Series release skipped", series_id: series.id, reason: reason)
        error
    end
  end

  # Released whole, a series request has nothing left to come: it is closed
  # with its sessions.
  defp release_in_transaction(series, changes) do
    released = Enum.map(lock_held(series), &release_session(&1, changes))
    :ok = SeriesCancel.close_in_transaction(series.id)
    released
  end

  defp release_session(meeting, changes) do
    case MeetingTransitionQueries.transition_from_awaiting_approval(meeting.id, changes) do
      {:ok, released} -> released
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # As for a single request: off the calendars, the video provider and the
  # request jobs first, then the refund, then the people told. Each step is
  # best-effort: the release has committed and cannot be undone.
  defp after_release(series, released, announce) do
    Enum.each(released, &MeetingApproval.clear_released_request/1)

    best_effort(series, "refund unapproved series", fn ->
      ApprovalRefunds.refund_unapproved_series(series, released)
    end)

    best_effort(series, "announce release", fn -> announce.(released) end)
  end

  # Integrations hear of the series once (`meeting.series_declined`,
  # `meeting.series_request_expired`), as they heard of its request; the
  # booker reads one email.
  defp announce_outcome(series, released, variant) when variant in [:declined, :expired] do
    announce_release_to_automations(series, released, variant)
    Notifications.schedule_series_request_outcome(series, variant)
  end

  defp announce_release_to_automations(_series, [], _variant), do: :ok

  defp announce_release_to_automations(series, released, variant) do
    series
    |> Automation.request_ended_job(variant, Enum.map(released, & &1.id))
    |> Oban.insert()
  end

  # A withdrawn request is cancelled whole: integrations hear one
  # `meeting.series_cancelled`, as they heard one `meeting.series_requested`.
  defp announce_withdrawal(series, released, withdrawn_by) do
    announce_withdrawal_to_automations(series, released)
    Notifications.schedule_series_cancellation(series, released, cancelled_by(withdrawn_by))
  end

  defp announce_withdrawal_to_automations(_series, []), do: :ok

  defp announce_withdrawal_to_automations(series, released) do
    series
    |> Automation.cancelled_job(Enum.map(released, & &1.id))
    |> Oban.insert()
  end

  defp cancelled_by(:attendee), do: :attendee
  defp cancelled_by(_calendar_or_organizer), do: :organizer

  # Locks

  # The organiser's schedule, the series, then its sessions in series order:
  # the order every writer of a series takes them in. Rolls back with
  # `:not_awaiting_approval` when the series request is no longer open (see
  # `series_request?/1`): answered, withdrawn, or only a session moved back
  # into the gate on its own, which is no series request at all.
  defp lock_held(series) do
    :ok = MeetingConflictQueries.lock_organizer_schedule(series.organizer_user_id)

    with %SeriesSchema{} <- SeriesQueries.lock(series),
         sessions = SeriesQueries.lock_meetings(series),
         true <- open_request?(sessions) do
      Enum.filter(sessions, &MeetingState.awaiting_approval?/1)
    else
      _gone_or_answered -> Repo.rollback(:not_awaiting_approval)
    end
  end

  # See `Tymeslot.Meetings.Approval`'s own: a raise in one step of work that
  # follows a committed release must not stop the next.
  defp best_effort(series, step, fun) do
    fun.()
  rescue
    exception in DispatchInTransactionError ->
      reraise exception, __STACKTRACE__

    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{step: step, series_id: series.id})
  end
end
