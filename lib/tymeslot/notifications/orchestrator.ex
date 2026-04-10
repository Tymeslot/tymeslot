defmodule Tymeslot.Notifications.Orchestrator do
  @moduledoc """
  Orchestrates the scheduling and sending of notifications.
  Coordinates between notification rules, recipients, and content building.
  """

  require Logger

  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Notifications.{ContentBuilder, Recipients, SchedulingRules}
  alias Tymeslot.Utils.ReminderUtils

  @doc """
  Schedules all notifications for a newly created meeting.
  """
  @spec schedule_meeting_notifications(%{atom() => term()}) :: {:ok, atom()} | {:error, term()}
  def schedule_meeting_notifications(meeting) do
    Logger.info("Scheduling notifications for meeting", meeting_id: meeting.id)

    with :ok <- schedule_confirmation_notifications(meeting),
         result <- schedule_reminder_notifications(meeting) do
      case result do
        :ok -> {:ok, :notifications_scheduled}
        {:ok, _result} -> {:ok, :notifications_scheduled}
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
  @spec schedule_confirmation_notifications(%{atom() => term()}) :: :ok | {:error, term()}
  def schedule_confirmation_notifications(meeting) do
    recipients = Recipients.determine_recipients(meeting, :confirmation)
    content = ContentBuilder.build_appointment_details(meeting)
    timing = SchedulingRules.confirmation_email_timing()

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content),
         result <- schedule_email_job(:confirmation, meeting.id, content, timing) do
      case result do
        :ok -> :ok
        {:ok, _result} -> :ok
        error -> error
      end
    end
  end

  @doc """
  Schedules reminder notifications for a meeting.
  """
  @spec schedule_reminder_notifications(%{atom() => term()}) ::
          :ok | {:ok, atom()} | {:error, term()}
  def schedule_reminder_notifications(meeting) do
    reminders =
      case Map.get(meeting, :reminders) do
        nil ->
          # Legacy meetings without reminders field - derive from legacy fields
          legacy_label = meeting.reminder_time || meeting.default_reminder_time || "30 minutes"
          value = ReminderUtils.parse_reminder_value(legacy_label)
          unit = ReminderUtils.normalize_reminder_unit(legacy_label)
          [%{value: value, unit: unit}]

        reminder_list ->
          normalized = normalize_reminders(reminder_list)
          # Respect empty list as "no reminders" - only default when nil
          normalized
      end

    recipients = Recipients.determine_recipients(meeting, :reminder)
    content = ContentBuilder.build_reminder_details(meeting)
    timing = SchedulingRules.reminder_email_timing()

    with :ok <- Recipients.validate_recipients(recipients),
         :ok <- ContentBuilder.validate_content(content) do
      {result, scheduled_any?} = schedule_reminders(meeting, reminders, timing)

      case {result, scheduled_any?} do
        {:ok, true} -> :ok
        {:ok, false} -> {:ok, :reminder_not_scheduled}
        {error, _scheduled} -> error
      end
    end
  end

  @doc """
  Schedules cancellation notifications via EmailWorker.
  """
  @spec send_cancellation_notifications(%{atom() => term()}) ::
          {:ok, atom()} | {:error, term()}
  def send_cancellation_notifications(meeting) do
    recipients = Recipients.determine_recipients(meeting, :cancellation)

    with :ok <- Recipients.validate_recipients(recipients) do
      worker_module = get_email_worker_module()

      case worker_module.schedule_cancellation_emails(meeting.id) do
        :ok -> {:ok, :cancellation_scheduled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Sends reschedule notifications immediately.
  """
  @spec send_reschedule_notifications(%{atom() => term()}, %{atom() => term()}) ::
          {:ok, atom()} | {:error, term()}
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
  @spec handle_video_room_notifications(%{atom() => term()}, :created | :failed) ::
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
  @spec get_notification_status(%{atom() => term()}) :: %{
          required(:confirmation_sent) => boolean() | nil,
          required(:reminder_scheduled) => boolean(),
          required(:reminder_sent) => boolean() | nil,
          required(:last_notification) => DateTime.t() | nil
        }
  def get_notification_status(meeting) do
    %{
      confirmation_sent: meeting.organizer_email_sent || meeting.attendee_email_sent,
      # We don't track this in the schema
      reminder_scheduled: false,
      reminder_sent: meeting.reminder_email_sent,
      last_notification: get_last_notification_time(meeting)
    }
  end

  @doc """
  Schedules calendar invitation emails for a list of attendees.

  Enqueues one Oban job per attendee via EmailWorker. Logs warnings for
  individual scheduling failures but does not abort the remaining attendees.
  """
  @spec schedule_calendar_invitations(pos_integer(), [String.t()], map()) :: :ok
  def schedule_calendar_invitations(_user_id, [], _event_details), do: :ok

  def schedule_calendar_invitations(user_id, attendee_emails, event_details) do
    worker_module = get_email_worker_module()

    Enum.each(attendee_emails, fn email ->
      params = %{
        user_id: user_id,
        attendee_email: email,
        event_title: event_details.title,
        event_uid: event_details.uid,
        event_start_at: DateTime.to_iso8601(event_details.start_at),
        event_end_at: DateTime.to_iso8601(event_details.end_at),
        event_location: event_details[:location],
        event_description: event_details[:description]
      }

      case worker_module.schedule_calendar_invitation(params) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to schedule invitation",
            attendee_email: email,
            reason: reason
          )
      end
    end)
  end

  @doc """
  Schedules a delayed event update notification for all attendees.

  Captures the "before" snapshot of attendee-relevant fields. The Oban job
  fires after 2 minutes, reads the current event state, diffs against the
  snapshot, and sends one email per attendee if changes remain.
  """
  @spec schedule_event_update_notification(pos_integer(), map()) :: :ok
  def schedule_event_update_notification(user_id, original_event) do
    attendee_emails = extract_attendee_emails(original_event.attendees)

    if attendee_emails == [] do
      :ok
    else
      worker_module = get_email_worker_module()

      case worker_module.schedule_event_update_notification(%{
             user_id: user_id,
             event_uid: original_event.uid,
             integration_id: original_event.calendar_integration_id,
             attendee_emails: attendee_emails,
             before_title: original_event.summary,
             before_location: original_event.location,
             before_description: original_event.description,
             before_start_at: original_event.start_at,
             before_end_at: original_event.end_at
           }) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to schedule event update notification",
            event_uid: original_event.uid,
            reason: reason
          )
      end

      :ok
    end
  end

  # Private functions

  defp extract_attendee_emails(nil), do: []

  defp extract_attendee_emails(attendees) do
    attendees
    |> Enum.map(&(&1["email"] || &1[:email]))
    |> Enum.filter(& &1)
  end

  defp schedule_email_job(
         notification_type,
         meeting_id,
         _content,
         _timing,
         schedule_at \\ nil,
         reminder_value \\ nil,
         reminder_unit \\ nil
       ) do
    worker_module = get_email_worker_module()

    case notification_type do
      :confirmation ->
        worker_module.schedule_confirmation_emails(meeting_id)

      :reminder ->
        worker_module.schedule_reminder_emails(
          meeting_id,
          reminder_value,
          reminder_unit,
          schedule_at
        )
    end
  end

  defp send_immediate_notifications(notification_type, content) do
    email_service = get_email_service_module()

    case notification_type do
      :reschedule ->
        email_service.send_appointment_confirmations(content)

      :video_room_failed ->
        # For now, just log this as we don't have this specific method yet
        Logger.info("Video room failed notification", content: content)
        {:ok, :video_room_notification_logged}
    end
  end

  defp update_confirmation_notifications(meeting, _content) do
    # Update already-scheduled reminder emails with video room information
    Logger.info("Updating scheduled notifications with video room info",
      meeting_id: meeting.id
    )

    # Acknowledge pending reminder jobs (emails re-fetch meeting data at send time)
    {:ok, count} = ObanJobQueries.update_pending_reminder_jobs(meeting)

    if count > 0 do
      Logger.info("Pending reminder jobs acknowledged",
        meeting_id: meeting.id,
        updated_count: count
      )
    else
      Logger.info("No pending reminder jobs required updates",
        meeting_id: meeting.id
      )
    end

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

  defp normalize_reminders(reminders) do
    ReminderUtils.normalize_reminders(reminders)
  end

  defp schedule_reminders(meeting, reminders, timing) do
    results =
      Enum.map(reminders, fn %{value: value, unit: unit} ->
        if SchedulingRules.should_schedule_reminder?(meeting.start_time, value, unit) do
          schedule_at = SchedulingRules.calculate_reminder_time(meeting.start_time, value, unit)

          case schedule_email_job(:reminder, meeting.id, %{}, timing, schedule_at, value, unit) do
            :ok -> {:ok, true}
            {:ok, _result} -> {:ok, true}
            error -> {error, false}
          end
        else
          Logger.info("Skipping reminder notification - meeting starts too soon",
            meeting_id: meeting.id,
            reminder: "#{value} #{unit}"
          )

          {:ok, false}
        end
      end)

    # Check if any failed
    error = Enum.find(results, &match?({{:error, _reason}, _sent}, &1))

    if error do
      {elem(error, 0), Enum.any?(results, &elem(&1, 1))}
    else
      {:ok, Enum.any?(results, &elem(&1, 1))}
    end
  end
end
