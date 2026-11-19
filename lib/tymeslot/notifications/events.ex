defmodule Tymeslot.Notifications.Events do
  @moduledoc """
  Defines notification events and their triggers.
  Pure functions for determining what notifications should be sent based on events.
  """

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.MeetingDeliveryQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.ChannelFanout
  alias Tymeslot.Notifications.DispatchInTransactionError
  alias Tymeslot.Notifications.Events.Guard
  alias Tymeslot.Notifications.Events.Seats
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Repo

  @doc """
  Handles meeting creation event.

  Raised once per booking (a reschedule into the approval gate is the one
  exception, below). A booking with a video room defers this
  event to `Tymeslot.Workers.VideoRoomWorker` so the payload can carry the join
  link, and that job announces the booking without one if the room is taking
  too long — a room that then arrives on a later attempt would otherwise fan
  the event out a second time, to every email, webhook, Telegram chat and Slack
  channel subscribed to it.

  The claim is taken before the fan-out rather than after it, so two callers
  racing cannot both dispatch. The claim, the confirmation emails and the
  reminders commit together or not at all: here they run in one transaction,
  so an email or reminder that cannot be enqueued releases the claim and
  returns the error for the caller (the video room job) to retry. The
  integration fan-out runs only once they have committed, so a retry can
  never announce the booking twice to webhooks, Telegram or Slack, and a
  failing integration never releases the claim: each channel is best-effort.

  A booking can win the claim a second time in one case: a reschedule sent it
  back into the approval gate, which frees the claim so the host's approval of
  the new time still gets the invitee their emails and reminders. To the
  integration channels that booking is not new, so webhooks, Telegram and
  Slack receive `meeting.rescheduled` for it instead, and `meeting.created`
  fires once per meeting across its whole life. The emails are the same either
  way: the confirmation is suppressed by its sent flags, and
  `Tymeslot.Meetings.Approval` sends the reschedule notice itself.
  """
  @spec meeting_created(term()) :: {:ok, term()} | {:error, term()}
  def meeting_created(meeting) do
    announcement =
      Repo.transaction(fn ->
        case meeting_created_deferred(meeting) do
          {{:error, reason}, _pending} -> Repo.rollback(reason)
          announced -> announced
        end
      end)

    with {:ok, {result, pending}} <- announcement do
      :ok = dispatch_deferred(pending)
      result
    end
  end

  @typedoc """
  The integration fan-out (webhooks, Telegram, Slack) an event still owes:
  for each dispatch, the channel event, the meeting it is about, and whether
  a group meeting fans out to every live seat (`:per_seat`), once (`:once`),
  or as one seat's booking (`{:seat, participant}`).
  """
  @type pending :: [{atom(), term(), :per_seat | :once | {:seat, term()}}]

  @doc """
  `meeting_created/1` without its integration fan-out, for a caller inside a
  transaction: the claim and the emails and reminders run now, and the
  webhook, Telegram and Slack dispatch is returned as `pending`, to be handed
  to `dispatch_deferred/1` once the transaction has committed.

  The emails and reminders are jobs, written in the caller's transaction, so
  they commit with the booking or not at all. On `{:error, _}` the caller
  must roll its transaction back, which releases the claim with it, and
  `pending` is empty: nothing is announced to the integrations for a booking
  whose emails were never queued. The integrations are kept out of the
  transaction because a database error inside a dispatcher, rescued here as
  best-effort, would still leave the caller's transaction unable to commit.

  Options:

    * `:emails` - `false` claims the announcement and schedules the
      reminders, but sends no confirmation emails: an occurrence of a
      booking series, whose booker and host are told about the whole series
      in one email instead. The claim still matters, so that a later
      reschedule of the occurrence is announced as a reschedule.
    * `:integrations` - `false` drops the `meeting.created` fan-out, for
      a series occurrence announced whole by `meeting.series_created`
      (`Tymeslot.BookingSeries.Automation`); a `meeting.rescheduled` stays.
  """
  @spec meeting_created_deferred(term(), keyword()) ::
          {{:ok, term()} | {:error, term()}, pending()}
  def meeting_created_deferred(meeting, opts \\ []) do
    emails? = Keyword.get(opts, :emails, true)
    created = if integrations?(opts), do: :meeting_created

    case MeetingDeliveryQueries.claim_announcement(Map.get(meeting, :id)) do
      {:ok, :first_announcement} -> announce_meeting_created(meeting, created, emails?)
      {:ok, :re_announcement} -> announce_meeting_created(meeting, :meeting_rescheduled, emails?)
      :already_announced -> {already_announced(meeting), []}
    end
  end

  defp integrations?(opts), do: Keyword.get(opts, :integrations, true)

  @doc """
  Runs the integration fan-out `meeting_created_deferred/2`,
  `meeting_requested_deferred/2` or `Tymeslot.Notifications.Events.Seats.seat_booked_deferred/3` returned. Never
  fails the caller: each channel is best-effort, and a failure is logged and
  reported.

  Raises `Tymeslot.Notifications.DispatchInTransactionError` when called
  inside a transaction, so a caller that dispatches before its commit, here
  or through `meeting_created/1`, `meeting_requested/2` or
  `Tymeslot.Bookings.Activation.after_commit/1`, fails on its first test
  rather than lose a booking in production.
  """
  @spec dispatch_deferred(pending()) :: :ok
  def dispatch_deferred(pending) when is_list(pending) do
    if MeetingDeliveryQueries.in_transaction?(), do: raise(DispatchInTransactionError)

    Enum.each(pending, fn {event, meeting, fan_out} ->
      dispatch_deferred_event(event, meeting, fan_out)
    end)
  end

  # The channels are each guarded already (`dispatch_channel/3`); this guards
  # what runs around them, such as reading a group meeting's seats.
  defp dispatch_deferred_event(event, meeting, fan_out) do
    case fan_out do
      :per_seat -> dispatch_integrations(event, meeting)
      :once -> dispatch_channels(event, meeting)
      {:seat, participant} -> Seats.dispatch(event, meeting, participant)
    end
  rescue
    exception ->
      Logger.error("Deferred integration dispatch failed",
        event: event,
        meeting_id: Map.get(meeting, :id),
        error: LogFormat.reason(exception)
      )

      ErrorTracking.report_error(exception, __STACKTRACE__, %{
        event: event,
        meeting_id: Map.get(meeting, :id)
      })
  end

  defp already_announced(meeting) do
    Logger.info("Meeting already announced, skipping the created event",
      meeting_id: Map.get(meeting, :id)
    )

    {:ok, :already_announced}
  end

  # `channel_event` is what webhooks, Telegram and Slack are told, nil for
  # nothing; the email and reminder fan-out is the same for both.
  defp announce_meeting_created(meeting, channel_event, emails?) do
    result =
      :meeting_created
      |> Guard.send_notifications(meeting, fn ->
        schedule_created_notifications(meeting, emails?)
      end)
      |> Guard.retryable_only(:meeting_created, meeting)

    case result do
      {:error, _reason} = error -> {error, []}
      result when is_nil(channel_event) -> {result, []}
      result -> {result, [{channel_event, meeting, :per_seat}]}
    end
  end

  defp schedule_created_notifications(meeting, true),
    do: Orchestrator.schedule_meeting_notifications(meeting)

  # `{:ok, :not_sendable}` (a meeting that cannot be emailed) passes through
  # as it is, as `schedule_meeting_notifications/1` reports it.
  defp schedule_created_notifications(meeting, false) do
    case Orchestrator.schedule_reminder_notifications(meeting) do
      :ok -> {:ok, :reminders_scheduled}
      {:ok, _outcome} = outcome -> outcome
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Handles a booking request being raised on a meeting type requiring approval.

  Fires `meeting.requested` rather than `meeting.created`. Consumers already
  read `meeting.created` as "a confirmed booking exists", and a held request
  is not one; it fires later, when the host approves. Meeting types without
  approval are unaffected and keep firing `meeting.created` on submission.

  `opts[:previous_start_time]` is passed on to the request emails by a
  reschedule that sent a confirmed booking back into the gate.
  """
  @spec meeting_requested(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def meeting_requested(meeting, opts \\ []) do
    {result, pending} = meeting_requested_deferred(meeting, opts)
    :ok = dispatch_deferred(pending)
    result
  end

  @doc """
  `meeting_requested/2` without its integration fan-out, for a caller inside
  a transaction; see `meeting_created_deferred/2`.

  `emails: false` schedules none of the request's emails, nudge or expiry,
  and returns no fan-out: a session of a booking series, whose request is
  sent once for the whole series, to people and automations alike
  (`Tymeslot.BookingSeries.Notifications.schedule_series_request/1`).
  """
  @spec meeting_requested_deferred(term(), keyword()) ::
          {{:ok, term()} | {:error, term()}, pending()}
  def meeting_requested_deferred(meeting, opts \\ []) do
    if Keyword.get(opts, :emails, true) do
      schedule_request(meeting, opts)
    else
      {{:ok, :requested_with_series}, []}
    end
  end

  defp schedule_request(meeting, opts) do
    result =
      :meeting_requested
      |> Guard.send_notifications(meeting, fn ->
        Orchestrator.schedule_request_notifications(meeting, opts)
      end)
      |> Guard.retryable_only(:meeting_requested, meeting)

    {result, [{:meeting_requested, meeting, :once}]}
  end

  @doc """
  Announces a video-room job's outcome for its meeting: the full
  `meeting_created/1` event for a solo meeting, or, for a group meeting,
  releasing every live seat's own confirmation email.

  A group meeting never raises `meeting_created/1` here.
  `Seats.seat_booked_deferred/3` fans its webhook/Telegram/Slack integrations
  out per seat at booking time, and `Tymeslot.Bookings.SeatEffects` schedules
  the reminders once, at whichever seat's booking created the meeting.
  Raising the full event on top of that would duplicate both, with a payload
  carrying no attendee at all, since a group meeting row has none of its own.

  Only the confirmation email was ever waiting on this: exactly one seat's,
  for a fresh booking, but releasing every live seat is safe. The job
  `Tymeslot.Notifications.Orchestrator.schedule_seat_confirmation/2`
  enqueues is uniqued on `(meeting_id, participant_id)`, and should a late
  release enqueue one anyway, the seat's own sent markers
  (`confirmation_sent_at`, `organizer_notified_at`) stop it sending again.

  Returns `{:error, reason}` when a solo meeting's emails could not be
  queued; nothing was announced, so the job retries.
  """
  @spec announce_video_room_outcome(term()) :: :ok | {:error, term()}
  def announce_video_room_outcome(meeting) do
    if MeetingSchema.group?(meeting) do
      Seats.release_confirmations(meeting)
    else
      with {:ok, _result} <- meeting_created(meeting), do: :ok
    end
  end

  @doc """
  Handles a booking request the host refused.

  Distinct from `meeting_cancelled/1` even though the stored status is the
  same. A cancellation tells the invitee a confirmed meeting is off; a decline
  tells them a request was never accepted, and sending the cancellation email
  here would refer to a booking they were explicitly told was not one.

  `emails: false` (here, in `meeting_request_expired/2` and in
  `meeting_cancelled/2`) skips the emails and runs only the integration
  fan-out. A booking series released whole calls neither: its people and
  its automations are told once for the whole series
  (`Tymeslot.BookingSeries.Approval`).
  """
  @spec meeting_declined(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def meeting_declined(meeting, opts \\ []),
    do: request_ended(meeting, :meeting_declined, :declined, opts)

  @doc """
  Handles a booking request nobody answered before its deadline.
  """
  @spec meeting_request_expired(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def meeting_request_expired(meeting, opts \\ []),
    do: request_ended(meeting, :meeting_request_expired, :expired, opts)

  defp request_ended(meeting, event, variant, opts) do
    result =
      if Keyword.get(opts, :emails, true) do
        Guard.send_notifications(event, meeting, fn ->
          Orchestrator.send_request_outcome_notifications(meeting, variant)
        end)
      else
        {:ok, :announced_with_series}
      end

    dispatch_channels(event, meeting)

    result
  end

  @doc """
  Handles meeting cancellation event.

  For a group meeting, integrations hear one `meeting.cancelled` per seat
  still live when it was cancelled: the host calling the whole slot off
  cancels every one of those bookings, and the participant rows are left
  live by it. An emptied slot cancelled by its last leaver has no live seat
  left, and `Seats.seat_cancelled/3` already announced that seat.

  `integrations: false` tells no integration: a session cancelled with the
  rest of its series, announced whole by `meeting.series_cancelled`.
  """
  @spec meeting_cancelled(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def meeting_cancelled(meeting, opts \\ []) do
    # Send email notifications
    result =
      if Keyword.get(opts, :emails, true) do
        Guard.send_notifications(:meeting_cancelled, meeting, fn ->
          Orchestrator.send_cancellation_notifications(meeting)
        end)
      else
        {:ok, :announced_with_series}
      end

    # Cancel pending reminders — a cancellation event already tells us the
    # slot is void, so call the canceller directly. Failures are logged but
    # never fail the cancellation itself.
    cancel_reminders(meeting)

    if integrations?(opts), do: dispatch_integrations(:meeting_cancelled, meeting)

    result
  end

  @doc """
  Handles meeting rescheduling event.

  `opts` are passed on to the reschedule emails: `moved_by: :host` marks a
  move the host made in their own calendar, which the organiser's copy says
  instead of blaming the attendee.
  """
  @spec meeting_rescheduled(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def meeting_rescheduled(updated_meeting, original_meeting, opts \\ []) do
    # Send email notifications
    result =
      Guard.send_notifications(:meeting_rescheduled, updated_meeting, fn ->
        Orchestrator.send_reschedule_notifications(updated_meeting, original_meeting, opts)
      end)

    # Reminders were re-pinned to the new time in the reschedule's own
    # transaction (`Tymeslot.Bookings.Reschedule`), so they committed with it.

    dispatch_integrations(:meeting_rescheduled, updated_meeting)

    result
  end

  @doc """
  Handles an organizer's reschedule request: the current time slot becomes
  void, so any pending reminder jobs still pointing at it are cancelled.
  Rebooking (`meeting_rescheduled/2`) recreates them.

  Unlike the other event handlers here, failures are NOT swallowed: voiding
  the slot is a correctness invariant the caller (`Bookings.RescheduleRequest`)
  must be able to react to, not a best-effort side notification.
  """
  @spec reschedule_requested(term()) :: :ok | {:error, term()}
  def reschedule_requested(meeting) do
    cancel_reminders_strict(meeting)
  end

  # Webhooks, Telegram and Slack; none of them fails the event that raised
  # it. A meeting-level event on a group meeting reaches integrations once per
  # live seat, each as that seat's booking: the slot row has no attendee, and
  # one event for it would name nobody.
  defp dispatch_integrations(event, %MeetingSchema{} = meeting) do
    if MeetingSchema.group?(meeting) do
      Guard.seat_guard(event, meeting, fn ->
        # Every seat's event fires at the same moment, so they share one count.
        seats_taken = ParticipantQueries.count_seats_taken(meeting.id)

        meeting.id
        |> ParticipantQueries.list_live_for_meeting()
        |> Enum.each(&dispatch_channels(event, SeatView.at_event(meeting, &1, seats_taken)))
      end)
    else
      dispatch_channels(event, meeting)
    end
  end

  defp dispatch_integrations(event, meeting), do: dispatch_channels(event, meeting)

  # Every event, the request-lifecycle ones (`meeting.requested`,
  # `meeting.declined`, `meeting.request_expired`) included, fans out to all
  # three channels through `ChannelFanout.dispatch/2`, which guards each
  # channel itself, so a raising channel cannot abort the fan-out or escape
  # into callers this module documents as non-failing. Each channel may
  # subscribe to every event (`Tymeslot.Notifications.EventTypes.all/0`).
  defp dispatch_channels(event, meeting), do: ChannelFanout.dispatch(event, meeting)

  defp cancel_reminders_strict(meeting) do
    Orchestrator.cancel_reminder_notifications(meeting)
  end

  defp cancel_reminders(meeting) do
    case Orchestrator.cancel_reminder_notifications(meeting) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to cancel reminder jobs",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
