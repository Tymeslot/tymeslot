defmodule Tymeslot.Notifications.Orchestrator do
  @moduledoc """
  Orchestrates the scheduling and sending of notifications.
  Coordinates between notification rules, recipients, and content building.
  """

  require Logger

  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Notifications.{ContentBuilder, Recipients, SchedulingRules}

  @doc """
  Schedules all notifications for a newly created meeting.
  """
  @spec schedule_meeting_notifications(map()) :: {:ok, atom()} | {:error, term()}
  def schedule_meeting_notifications(meeting) do
    Logger.info("Scheduling notifications for meeting", meeting_id: meeting.id)

    with :ok <- schedule_confirmation_notifications(meeting),
         result <- schedule_reminder_notifications(meeting) do
      case result do
        :ok -> {:ok, :notifications_scheduled}
        {:ok, _} -> {:ok, :notifications_scheduled}
        error -> error
      end
    else
      {:error, reason} = error ->
        Logger.error("Failed to schedule meeting notifications",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Schedules confirmation notifications for a meeting.
  """
  @spec schedule_confirmation_notifications(map()) :: :ok | {:error, term()}
  def schedule_confirmation_notifications(meeting) do
    recipients = Recipients.determine_recipients(meeting, :confirmation)
    content = ContentBuilder.build_appointment_details(meeting)
    timing = SchedulingRules.confirmation_email_timing()

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content),
         result <- schedule_email_job(:confirmation, meeting.id, content, timing) do
      case result do
        :ok -> :ok
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  @doc """
  Schedules reminder notifications for a meeting.
  """
  @spec schedule_reminder_notifications(map()) :: :ok | {:ok, atom()} | {:error, term()}
  def schedule_reminder_notifications(meeting) do
    case SchedulingRules.should_schedule_reminder?(meeting.start_time) do
      true ->
        recipients = Recipients.determine_recipients(meeting, :reminder)
        content = ContentBuilder.build_reminder_details(meeting)
        timing = SchedulingRules.reminder_email_timing()
        schedule_at = SchedulingRules.calculate_reminder_time(meeting.start_time)

        with :ok <- Recipients.validate_recipients(recipients),
             :ok <- ContentBuilder.validate_content(content),
             result <- schedule_email_job(:reminder, meeting.id, content, timing, schedule_at) do
          case result do
            :ok -> :ok
            {:ok, _} -> :ok
            error -> error
          end
        end

      false ->
        Logger.info("Skipping reminder notification - meeting starts too soon",
          meeting_id: meeting.id
        )

        {:ok, :reminder_not_scheduled}
    end
  end

  @doc """
  Sends cancellation notifications immediately.
  """
  @spec send_cancellation_notifications(map()) ::
          {:ok, atom()} | {:ok, :partial_success} | {:error, term()}
  def send_cancellation_notifications(meeting) do
    recipients = Recipients.determine_recipients(meeting, :cancellation)
    content = ContentBuilder.build_cancellation_details(meeting)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content) do
      # Send immediately via EmailService
      send_immediate_notifications(:cancellation, content)
    end
  end

  @doc """
  Sends reschedule notifications immediately.
  """
  @spec send_reschedule_notifications(map(), map()) :: {:ok, atom()} | {:error, term()}
  def send_reschedule_notifications(updated_meeting, original_meeting) do
    recipients = Recipients.determine_recipients(updated_meeting, :reschedule)
    content = ContentBuilder.build_reschedule_details(updated_meeting, original_meeting)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content) do
      # Send immediately via EmailService
      send_immediate_notifications(:reschedule, content)
    end
  end

  @doc """
  Handles video room notifications.
  """
  @spec handle_video_room_notifications(map(), :created | :failed) ::
          {:ok, atom()} | :ok | {:error, term()}
  def handle_video_room_notifications(meeting, video_room_status) do
    notification_type =
      case video_room_status do
        :created -> :video_room_created
        :failed -> :video_room_failed
      end

    recipients = Recipients.determine_recipients(meeting, notification_type)
    content = ContentBuilder.build_video_room_details(meeting, video_room_status)

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content) do
      case video_room_status do
        :created ->
          # Update existing confirmation emails with video room info
          update_confirmation_notifications(meeting, content)

        :failed ->
          # Send fallback notification to organizer
          send_immediate_notifications(:video_room_failed, content)
      end
    end
  end

  @doc """
  Gets notification status for a meeting.
  """
  @spec get_notification_status(map()) :: map()
  def get_notification_status(meeting) do
    %{
      confirmation_sent: meeting.organizer_email_sent || meeting.attendee_email_sent,
      # We don't track this in the schema
      reminder_scheduled: false,
      reminder_sent: meeting.reminder_email_sent,
      last_notification: get_last_notification_time(meeting)
    }
  end

  # Private functions

  defp schedule_email_job(notification_type, meeting_id, _content, _timing, _schedule_at \\ nil) do
    worker_module = get_email_worker_module()

    case notification_type do
      :confirmation ->
        worker_module.schedule_confirmation_emails(meeting_id)

      :reminder ->
        worker_module.schedule_reminder_emails(meeting_id)
    end
  end

  defp send_immediate_notifications(notification_type, content) do
    email_service = get_email_service_module()

    case notification_type do
      :cancellation ->
        case email_service.send_cancellation_emails(content) do
          {{:ok, _}, {:ok, _}} ->
            {:ok, :emails_sent}

          {organizer_result, attendee_result} ->
            Logger.warning("Some cancellation emails may have failed",
              organizer_result: inspect(organizer_result),
              attendee_result: inspect(attendee_result)
            )

            {:ok, :partial_success}
        end

      :reschedule ->
        email_service.send_appointment_confirmations(content)

      :video_room_failed ->
        # For now, just log this as we don't have this specific method yet
        Logger.info("Video room failed notification", content: content)
        {:ok, :video_room_notification_logged}
    end
  end

  defp update_confirmation_notifications(meeting, _content) do
    # This would update already-scheduled confirmation emails
    # with video room information
    Logger.info("Updating confirmation notifications with video room info",
      meeting_id: meeting.id
    )

    {:ok, :confirmation_updated}
  end

  defp get_last_notification_time(meeting) do
    # Since we don't have timestamp fields for when emails were sent,
    # we'll just use updated_at as the last notification time
    meeting.updated_at
  end

  # Module getters for dependency injection in tests
  defp get_email_worker_module do
    Application.get_env(:tymeslot, :email_worker_module, Tymeslot.Workers.EmailWorker)
  end

  defp get_email_service_module do
    Application.get_env(:tymeslot, :email_service_module, EmailService)
  end
end
