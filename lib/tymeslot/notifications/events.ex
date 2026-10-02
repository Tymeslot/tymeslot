defmodule Tymeslot.Notifications.Events do
  @moduledoc """
  Defines notification events and their triggers.
  Pure functions for determining what notifications should be sent based on events.
  """

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Slack.Dispatcher, as: SlackDispatcher
  alias Tymeslot.Telegram.Dispatcher, as: TelegramDispatcher
  alias Tymeslot.Webhooks.Dispatcher

  @doc """
  Handles meeting creation event.

  Raised at most once per meeting. A booking with a video room defers this
  event to `Tymeslot.Workers.VideoRoomWorker` so the payload can carry the join
  link, and that job announces the booking without one if the room is taking
  too long — a room that then arrives on a later attempt would otherwise fan
  the event out a second time, to every email, webhook, Telegram chat and Slack
  channel subscribed to it.

  The claim is taken before the fan-out rather than after it, so two callers
  racing cannot both dispatch. A fan-out that then fails keeps the claim: every
  channel here is best-effort and none of the callers retry the event, so
  releasing it would buy nothing and would risk announcing twice instead.

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
    case MeetingQueries.claim_announcement(Map.get(meeting, :id)) do
      {:ok, :first_announcement} -> dispatch_meeting_created(meeting, :meeting_created)
      {:ok, :re_announcement} -> dispatch_meeting_created(meeting, :meeting_rescheduled)
      :already_announced -> already_announced(meeting)
    end
  end

  defp already_announced(meeting) do
    Logger.info("Meeting already announced, skipping the created event",
      meeting_id: Map.get(meeting, :id)
    )

    {:ok, :already_announced}
  end

  # `channel_event` is what webhooks, Telegram and Slack are told; the email
  # and reminder fan-out is the same for both announcements.
  defp dispatch_meeting_created(meeting, channel_event) do
    result =
      send_notifications(:meeting_created, meeting, fn ->
        Orchestrator.schedule_meeting_notifications(meeting)
      end)

    dispatch_integrations(channel_event, meeting)

    result
  end

  @doc """
  Handles a seat being booked on a group meeting.

  Every seat schedules its own confirmation email job (participant plus a
  per-seat organiser notification). Reminders are meeting-level and scheduled
  exactly once, by `Tymeslot.Bookings.SeatEffects` at whichever seat's
  booking created the meeting — not here, so this never needs to know
  `created_meeting?`.

  The integration dispatchers fire per seat, not per slot, because a booking
  is a person: a host's webhook, Telegram or Slack automation needs to hear
  about the fifth booker as much as the first. Each carries that seat's
  participant (see `Tymeslot.Meetings.SeatView`), since the shared meeting
  row has no attendee of its own.

  Options:
    * `:defer_emails?` — the caller has scheduled video-room creation and the
      room worker will release this seat's confirmation once the join link
      exists, so scheduling it here would only send a linkless duplicate.
  """
  @spec seat_booked(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def seat_booked(meeting, participant, opts \\ []) do
    result =
      if Keyword.get(opts, :defer_emails?, false) do
        {:ok, :deferred_to_video_room}
      else
        Orchestrator.schedule_seat_confirmation(meeting, participant)
      end

    dispatch_seat(:meeting_created, meeting, participant)

    result
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
    result =
      send_notifications(:meeting_requested, meeting, fn ->
        Orchestrator.schedule_request_notifications(meeting, opts)
      end)

    dispatch_request_channels(:meeting_requested, meeting)

    result
  end

  @doc """
  Announces a video-room job's outcome for its meeting: the full
  `meeting_created/1` event for a solo meeting, or — for a group meeting —
  releasing every live seat's own confirmation email.

  A group meeting never raises `meeting_created/1` here. `seat_booked/3`
  already fanned its webhook/Telegram/Slack integrations out per seat at
  booking time, and reminders were already scheduled once, at whichever
  seat's booking created the meeting (see `Tymeslot.Bookings.SeatEffects`).
  Re-raising the full event on top of that duplicated it with a payload
  carrying no attendee at all, since a group meeting row has none of its own.

  Only the confirmation email was ever waiting on this: exactly one seat's,
  for a fresh booking, but every live seat's release is idempotent —
  `Tymeslot.Notifications.Orchestrator.schedule_seat_confirmation/2` is
  uniqued on `(meeting_id, participant_id)`, so releasing an already-sent
  seat here is a no-op in the common case. Only a room recovery spanning past
  that job's uniqueness window could resend one; still a better trade than
  the group confirmation this replaces silently dropping the first booker's
  email outright.
  """
  @spec announce_video_room_outcome(term()) :: :ok
  def announce_video_room_outcome(meeting) do
    if MeetingSchema.group?(meeting) do
      release_seat_confirmations(meeting)
    else
      meeting_created(meeting)
    end

    :ok
  end

  # A room job that finishes after the host cancelled the meeting has no
  # confirmations left to release: the participants were told it is off.
  defp release_seat_confirmations(%{status: "cancelled"}), do: :ok

  defp release_seat_confirmations(meeting) do
    meeting.id
    |> ParticipantQueries.list_live_for_meeting()
    |> Enum.each(&Orchestrator.schedule_seat_confirmation(meeting, &1))
  end

  @doc """
  Handles a participant cancelling their seat on a group meeting.

  Schedules the seat-cancellation emails. `slot_freed: true` marks the last
  leaver: their leaving cancelled the meeting, and the organiser's email
  about the seat says so (it is the organiser's only email about it).

  Integrations hear `meeting.cancelled` for this seat. For the last leaver
  that is the only one: the meeting-level cancellation that follows finds no
  live seat left to announce, and an empty slot was never a booking.
  """
  @spec seat_cancelled(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def seat_cancelled(meeting, participant, opts \\ []) do
    result =
      Orchestrator.schedule_seat_cancellation(
        meeting,
        participant,
        Keyword.get(opts, :slot_freed, false)
      )

    dispatch_seat(:meeting_cancelled, meeting, participant)

    result
  end

  @doc """
  Handles a participant's seat moving to a new slot (move-my-seat).

  Schedules the reschedule email: a confirmation for the new seat whose
  attachments also cancel the old seat's calendar entry for the participant,
  and the matching cancellation and invitation for their guests.
  `old_participant` is the seat row the move cancelled; each seat is its own
  calendar entry, so the old one is named by that row, not by the old
  meeting. `old_slot_freed: true` says the move emptied, and so cancelled,
  the old meeting.

  Integrations hear `meeting.rescheduled` for the new seat, the way a solo
  booking's move is one rescheduled booking rather than a cancellation and a
  new one.
  """
  @spec seat_rescheduled(term(), term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def seat_rescheduled(meeting, participant, old_participant, opts \\ []) do
    result =
      Orchestrator.schedule_seat_reschedule(
        meeting,
        participant,
        old_participant,
        Keyword.get(opts, :old_slot_freed, false)
      )

    dispatch_seat(:meeting_rescheduled, meeting, participant)

    result
  end

  @doc """
  Handles a booking request the host refused.

  Distinct from `meeting_cancelled/1` even though the stored status is the
  same. A cancellation tells the invitee a confirmed meeting is off; a decline
  tells them a request was never accepted, and sending the cancellation email
  here would refer to a booking they were explicitly told was not one.
  """
  @spec meeting_declined(term()) :: {:ok, term()} | {:error, term()}
  def meeting_declined(meeting), do: request_ended(meeting, :meeting_declined, :declined)

  @doc """
  Handles a booking request nobody answered before its deadline.
  """
  @spec meeting_request_expired(term()) :: {:ok, term()} | {:error, term()}
  def meeting_request_expired(meeting),
    do: request_ended(meeting, :meeting_request_expired, :expired)

  defp request_ended(meeting, event, variant) do
    result =
      send_notifications(event, meeting, fn ->
        Orchestrator.send_request_outcome_notifications(meeting, variant)
      end)

    dispatch_request_channels(event, meeting)

    result
  end

  @doc """
  Handles meeting cancellation event.

  For a group meeting, integrations hear one `meeting.cancelled` per seat
  still live when it was cancelled: the host calling the whole slot off
  cancels every one of those bookings, and the participant rows are left
  live by it. An emptied slot cancelled by its last leaver has no live seat
  left, and `seat_cancelled/3` already announced that seat.
  """
  @spec meeting_cancelled(term()) :: {:ok, term()} | {:error, term()}
  def meeting_cancelled(meeting) do
    # Send email notifications
    result =
      send_notifications(:meeting_cancelled, meeting, fn ->
        Orchestrator.send_cancellation_notifications(meeting)
      end)

    # Cancel pending reminders — a cancellation event already tells us the
    # slot is void, so call the canceller directly. Failures are logged but
    # never fail the cancellation itself.
    cancel_reminders(meeting)

    # Webhooks, Telegram and Slack; none of them fails the cancellation.
    dispatch_integrations(:meeting_cancelled, meeting)

    result
  end

  @doc """
  Handles meeting rescheduling event.
  """
  @spec meeting_rescheduled(term(), term()) :: {:ok, term()} | {:error, term()}
  def meeting_rescheduled(updated_meeting, original_meeting) do
    # Send email notifications
    result =
      send_notifications(:meeting_rescheduled, updated_meeting, fn ->
        Orchestrator.send_reschedule_notifications(updated_meeting, original_meeting)
      end)

    # Re-pin reminders to the new meeting time. This replaces reminder jobs
    # still aimed at the old time and recreates the ones deleted when an
    # organizer reschedule request voided the original slot. Failures are
    # logged but never fail the reschedule itself.
    schedule_reminders(updated_meeting)

    # Webhooks, Telegram and Slack; none of them fails the reschedule.
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

  # The email step is the only one of these dispatches that renders templates
  # in-process, so a payload the templates don't fit raises instead of
  # returning `{:error, _}`. Everything sequenced after it — reminder jobs,
  # webhooks, Telegram, Slack — is best-effort by design, and an escaping
  # exception used to skip all of them while the meeting change itself stood
  # (issue #76: a reschedule that never dispatched `meeting.rescheduled`).
  # Contain it here so one failed channel cannot silence the others; the caller
  # still learns the emails failed through the error tuple it already handles.
  defp send_notifications(event, meeting, fun) do
    fun.()
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{
        event: event,
        meeting_id: Map.get(meeting, :id)
      })

      {:error, {:notifications_failed, exception}}
  end

  # `Dispatcher.dispatch/2` (and its Telegram/Slack counterparts) resolves an
  # internal event atom to a wire name via `EventTypes.to_event_type/1`, which
  # raises on an atom it doesn't recognise. These three calls sit outside the
  # `send_notifications/3` rescue, on purpose — that rescue is scoped to the
  # in-process email render — so each dispatch gets its own guard: a channel
  # that can't resolve the event name is best-effort like the rest of the
  # fan-out, not a reason to abort the remaining channels or escape into the
  # booking caller.
  defp dispatch_webhooks(event, meeting), do: dispatch_channel(:webhooks, event, meeting)
  defp dispatch_telegram(event, meeting), do: dispatch_channel(:telegram, event, meeting)
  defp dispatch_slack(event, meeting), do: dispatch_channel(:slack, event, meeting)

  # A meeting-level event on a group meeting reaches integrations once per
  # live seat, each as that seat's booking: the slot row has no attendee, and
  # one event for it would name nobody.
  defp dispatch_integrations(event, %MeetingSchema{} = meeting) do
    if MeetingSchema.group?(meeting) do
      seat_guard(event, meeting, fn ->
        meeting.id
        |> ParticipantQueries.list_live_for_meeting()
        |> Enum.each(&dispatch_channels(event, SeatView.at_event(meeting, &1)))
      end)
    else
      dispatch_channels(event, meeting)
    end
  end

  defp dispatch_integrations(event, meeting), do: dispatch_channels(event, meeting)

  defp dispatch_seat(event, meeting, participant) do
    seat_guard(event, meeting, fn ->
      dispatch_channels(event, SeatView.at_event(meeting, participant))
    end)
  end

  # Building a seat's view reads the database (its live seats, the seat
  # count), which the per-channel guard below does not cover. It is as
  # best-effort as the channels themselves, so it gets a guard of its own.
  defp seat_guard(event, meeting, fun) do
    fun.()
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{
        channel: :seats,
        event: event,
        meeting_id: Map.get(meeting, :id)
      })

      {:error, {:dispatch_failed, exception}}
  end

  defp dispatch_channels(event, meeting) do
    dispatch_webhooks(event, meeting)
    dispatch_telegram(event, meeting)
    dispatch_slack(event, meeting)
  end

  # The three request-lifecycle events (`meeting.requested`,
  # `meeting.declined`, `meeting.request_expired`) fan out to all three
  # channels through the same guarded `dispatch_channel/3` as every other
  # event, so a raising channel cannot abort the fan-out or escape into
  # callers this module documents as non-failing.
  #
  # Telegram finds nothing to notify for now:
  # `TelegramIntegrationSchema.@valid_events` still hardcodes the
  # pre-approval three, so no integration can be subscribed to these events
  # yet. It is dispatched anyway rather than special-cased, so widening that
  # allowlist is the only change Telegram will need.
  #
  # Slack does reach real subscribers today — `SlackIntegrationSchema`'s
  # `@valid_events` derives from `EventTypes.all/0` and
  # `Slack.default_events_for_new_integration/0` subscribes fresh
  # integrations to all of them — and `Slack.MessageBuilder` now has
  # dedicated rendering for all three, so what a host sees is a real
  # notification rather than the generic "Meeting update" fallback.
  defp dispatch_request_channels(event, meeting), do: dispatch_channels(event, meeting)

  defp dispatch_channel(channel, event, meeting) do
    dispatch_fun(channel).(event, meeting)
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{
        channel: channel,
        event: event,
        meeting_id: Map.get(meeting, :id)
      })

      {:error, {:dispatch_failed, exception}}
  end

  defp dispatch_fun(:webhooks), do: &Dispatcher.dispatch/2
  defp dispatch_fun(:telegram), do: &TelegramDispatcher.dispatch/2
  defp dispatch_fun(:slack), do: &SlackDispatcher.dispatch/2

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

  defp schedule_reminders(meeting) do
    case Orchestrator.schedule_reminder_notifications(meeting) do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        # The legitimate "nothing to schedule" case (meeting starts too soon
        # for any configured reminder) is `{:ok, :reminder_not_scheduled}`,
        # matched above, not an error. Anything reaching here is a real
        # defect that silently deprives a meeting of its reminders, so it is
        # logged loudly rather than as a routine warning.
        Logger.error("Failed to schedule reminder jobs",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
