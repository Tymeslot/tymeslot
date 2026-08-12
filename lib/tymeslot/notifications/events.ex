defmodule Tymeslot.Notifications.Events do
  @moduledoc """
  Defines notification events and their triggers.
  Pure functions for determining what notifications should be sent based on events.
  """

  require Logger

  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Slack.Dispatcher, as: SlackDispatcher
  alias Tymeslot.Telegram.Dispatcher, as: TelegramDispatcher
  alias Tymeslot.Webhooks.Dispatcher

  @doc """
  Handles meeting creation event.
  """
  @spec meeting_created(term()) :: {:ok, term()} | {:error, term()}
  def meeting_created(meeting) do
    # Send email notifications
    result =
      send_notifications(:meeting_created, meeting, fn ->
        Orchestrator.schedule_meeting_notifications(meeting)
      end)

    # Dispatch webhooks (don't fail if webhooks fail)
    Dispatcher.dispatch(:meeting_created, meeting)

    # Dispatch Telegram notifications (don't fail if Telegram fails)
    TelegramDispatcher.dispatch(:meeting_created, meeting)

    # Dispatch Slack notifications (don't fail if Slack fails)
    SlackDispatcher.dispatch(:meeting_created, meeting)

    result
  end

  @doc """
  Handles a seat being booked on a group meeting.

  Every seat schedules its own confirmation email job (participant plus a
  per-seat organiser notification). `created_meeting?` marks the first seat:
  reminder jobs are meeting-level, so they are scheduled exactly once here.

  The integration dispatchers fire per seat, not per slot, because a booking
  is a person: a host's webhook, Telegram or Slack automation needs to hear
  about the fifth booker as much as the first. Each carries that seat's
  participant, since the shared meeting row has no attendee of its own.

  Options:
    * `:defer_emails?` — the caller has scheduled video-room creation and the
      room worker will release this seat's confirmation once the join link
      exists, so scheduling it here would only send a linkless duplicate.
  """
  @spec seat_booked(term(), term(), boolean(), keyword()) :: {:ok, term()} | {:error, term()}
  def seat_booked(meeting, participant, created_meeting?, opts \\ []) do
    result =
      if Keyword.get(opts, :defer_emails?, false) do
        {:ok, :deferred_to_video_room}
      else
        Orchestrator.schedule_seat_confirmation(meeting, participant)
      end

    if created_meeting?, do: schedule_reminders(meeting)

    dispatch_seat_integrations(meeting, participant)

    result
  end

  defp dispatch_seat_integrations(meeting, participant) do
    seat_meeting = Recipient.meeting_as_seen_by(meeting, participant)

    Dispatcher.dispatch(:meeting_created, seat_meeting)
    TelegramDispatcher.dispatch(:meeting_created, seat_meeting)
    SlackDispatcher.dispatch(:meeting_created, seat_meeting)
  end

  @doc """
  Handles a participant cancelling their seat on a group meeting.

  Schedules the seat-cancellation emails. `notify_organizer: false` is used
  by the last-leaver path, where the meeting-level cancellation flow already
  emails the organiser.
  """
  @spec seat_cancelled(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def seat_cancelled(meeting, participant, opts \\ []) do
    notify_organizer? = Keyword.get(opts, :notify_organizer, true)
    Orchestrator.schedule_seat_cancellation(meeting, participant, notify_organizer?)
  end

  @doc """
  Handles a participant's seat moving to a new slot (move-my-seat).

  Schedules the reschedule email: a confirmation for the new meeting whose
  attachments also cancel the old meeting's event in the participant's
  calendar. The old event snapshot is passed through the job args because
  the old meeting may already be cancelled or mutated by the time the job
  runs.
  """
  @spec seat_rescheduled(term(), term(), map()) :: {:ok, term()} | {:error, term()}
  def seat_rescheduled(meeting, participant, old_snapshot) do
    Orchestrator.schedule_seat_reschedule(meeting, participant, old_snapshot)
  end

  @doc """
  Handles meeting cancellation event.
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

    # Dispatch webhooks (don't fail if webhooks fail)
    Dispatcher.dispatch(:meeting_cancelled, meeting)

    # Dispatch Telegram notifications (don't fail if Telegram fails)
    TelegramDispatcher.dispatch(:meeting_cancelled, meeting)

    # Dispatch Slack notifications (don't fail if Slack fails)
    SlackDispatcher.dispatch(:meeting_cancelled, meeting)

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

    # Dispatch webhooks (don't fail if webhooks fail)
    Dispatcher.dispatch(:meeting_rescheduled, updated_meeting)

    # Dispatch Telegram notifications (don't fail if Telegram fails)
    TelegramDispatcher.dispatch(:meeting_rescheduled, updated_meeting)

    # Dispatch Slack notifications (don't fail if Slack fails)
    SlackDispatcher.dispatch(:meeting_rescheduled, updated_meeting)

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
      Logger.error("Notification emails failed",
        event: event,
        meeting_id: Map.get(meeting, :id),
        error: Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:notifications_failed, exception}}
  end

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
          reason: inspect(reason)
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
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Handles video room creation success event.
  """
  @spec video_room_created(term()) :: {:ok, term()} | {:error, term()}
  def video_room_created(meeting) do
    Orchestrator.handle_video_room_notifications(meeting, :created)
  end

  @doc """
  Handles video room creation failure event.
  """
  @spec video_room_failed(term()) :: {:ok, term()} | {:error, term()}
  def video_room_failed(meeting) do
    Orchestrator.handle_video_room_notifications(meeting, :failed)
  end

  @doc """
  Handles meeting reminder trigger event.
  """
  @spec reminder_triggered(term()) :: {:ok, atom()}
  def reminder_triggered(_meeting) do
    # This would be called by the reminder job
    # The actual email sending is handled by the EmailWorker
    {:ok, :reminder_processed}
  end

  @doc """
  Handles meeting status change event.
  """
  @spec meeting_status_changed(term(), String.t(), String.t()) ::
          {:ok, atom()} | {:ok, term()} | {:error, term()}
  def meeting_status_changed(meeting, old_status, new_status) do
    case {old_status, new_status} do
      {_old, "cancelled"} ->
        meeting_cancelled(meeting)

      {_old, "completed"} ->
        # No notifications needed for completed meetings
        {:ok, :no_notifications}

      _status_change ->
        # Other status changes might need notifications in the future
        {:ok, :no_notifications}
    end
  end

  @doc """
  Determines if an event should trigger notifications.
  """
  @spec should_trigger_notifications?(atom(), term()) :: boolean()
  def should_trigger_notifications?(event_type, meeting) do
    case event_type do
      :meeting_created ->
        meeting.status == "confirmed"

      :meeting_cancelled ->
        meeting.status == "cancelled"

      :meeting_rescheduled ->
        meeting.status == "confirmed"

      :video_room_created ->
        meeting.video_room_enabled == true

      :video_room_failed ->
        meeting.video_room_enabled == false

      :reminder_triggered ->
        meeting.status == "confirmed" and
          meeting.reminder_email_sent == false

      _unknown_event ->
        false
    end
  end

  @doc """
  Gets event metadata for logging and tracking.
  """
  @spec get_event_metadata(atom(), term()) :: map()
  def get_event_metadata(event_type, meeting) do
    %{
      event_type: event_type,
      meeting_id: meeting.id,
      meeting_uid: meeting.uid,
      meeting_status: meeting.status,
      attendee_email: meeting.attendee_email,
      organizer_email: meeting.organizer_email,
      meeting_start: meeting.start_time,
      event_timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Validates that an event can be processed.
  """
  @spec validate_event(atom(), term()) :: :ok | {:error, String.t()}
  def validate_event(event_type, meeting) do
    cond do
      is_nil(meeting) ->
        {:error, "Meeting is required"}

      not should_trigger_notifications?(event_type, meeting) ->
        {:error, "Event should not trigger notifications"}

      true ->
        :ok
    end
  end
end
