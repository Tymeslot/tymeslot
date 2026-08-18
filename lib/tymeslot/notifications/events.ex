defmodule Tymeslot.Notifications.Events do
  @moduledoc """
  Defines notification events and their triggers.
  Pure functions for determining what notifications should be sent based on events.
  """

  require Logger

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
        Logger.warning("Failed to schedule reminder jobs",
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
