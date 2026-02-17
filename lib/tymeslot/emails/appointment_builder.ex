defmodule Tymeslot.Emails.AppointmentBuilder do
  @moduledoc """
  Builds appointment details payloads for email templates and delivery adapters.
  Extracted from EmailWorker to keep the worker focused on orchestration.
  """

  require Logger
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.ReminderUtils

  @default_timezone "Europe/Kyiv"

  @spec from_meeting(map(), map() | nil) :: map()
  def from_meeting(meeting, reminder_interval \\ nil) do
    owner_timezone = owner_timezone(meeting)
    attendee_timezone = attendee_timezone(meeting, owner_timezone)

    base_details = base_details(meeting)
    timezone_details = timezone_details(meeting, owner_timezone, attendee_timezone)
    participant_details = participant_details(meeting)
    preparation_details = preparation_details()
    url_details = url_details(meeting)
    reminder_details = reminder_details(meeting, reminder_interval)

    base_details
    |> Map.merge(timezone_details)
    |> Map.merge(participant_details)
    |> Map.merge(preparation_details)
    |> Map.merge(url_details)
    |> Map.merge(reminder_details)
  end

  defp owner_timezone(meeting) do
    case meeting.organizer_user_id do
      nil ->
        Logger.error(
          "Missing organizer_user_id for meeting #{meeting.uid}, using default timezone"
        )

        @default_timezone

      user_id ->
        Profiles.get_user_timezone(user_id)
    end
  end

  defp attendee_timezone(meeting, owner_timezone) do
    case meeting.attendee_timezone do
      nil ->
        Logger.warning(
          "Missing attendee_timezone for meeting #{meeting.uid}, using organizer timezone as emergency fallback"
        )

        owner_timezone

      timezone ->
        timezone
    end
  end

  defp base_details(meeting) do
    %{
      uid: meeting.uid,
      title: meeting.title,
      summary: meeting.summary || meeting.title,
      description: meeting.description || "",
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      date: DateTime.to_date(meeting.start_time),
      duration: meeting.duration,
      location: format_location(meeting),
      location_details: format_location_details(meeting),
      meeting_type: meeting.meeting_type
    }
  end

  defp timezone_details(meeting, owner_timezone, attendee_timezone) do
    %{
      attendee_timezone: attendee_timezone,
      start_time_owner_tz: convert_to_timezone(meeting.start_time, owner_timezone),
      end_time_owner_tz: convert_to_timezone(meeting.end_time, owner_timezone),
      start_time_attendee_tz: convert_to_timezone(meeting.start_time, attendee_timezone),
      end_time_attendee_tz: convert_to_timezone(meeting.end_time, attendee_timezone)
    }
  end

  defp participant_details(meeting) do
    %{
      # Organizer details
      organizer_name: meeting.organizer_name,
      organizer_email: meeting.organizer_email,
      organizer_title: meeting.organizer_title,
      organizer_contact_info: "reply to this email",

      # Attendee details
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email,
      attendee_message: meeting.attendee_message,
      attendee_phone: meeting.attendee_phone,
      attendee_company: meeting.attendee_company
    }
  end

  defp preparation_details do
    %{
      contact_info: "reply to this email",
      allow_contact: true,
      time_until_friendly: "in 30 minutes"
    }
  end

  defp url_details(meeting) do
    %{
      view_url: meeting.view_url || "#",
      reschedule_url: meeting.reschedule_url || "#",
      cancel_url: meeting.cancel_url || "#",
      meeting_url: meeting.meeting_url,
      organizer_video_url: meeting.organizer_video_url,
      attendee_video_url: meeting.attendee_video_url
    }
  end

  defp reminder_details(meeting, reminder_interval) do
    case ReminderUtils.normalize_reminder(reminder_interval) do
      {:ok, reminder} ->
        build_reminder_details_from_interval(reminder)

      _error ->
        meeting
        |> Map.get(:reminders)
        |> ReminderUtils.normalize_reminders()
        |> handle_normalized_reminders(meeting)
    end
  end

  defp build_reminder_details_from_interval(%{value: value, unit: unit}) do
    reminder_label = ReminderUtils.format_reminder_label(value, unit)

    %{
      reminder_time: reminder_label,
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: "in #{reminder_label}",
      reminders_enabled: true,
      reminders_summary: "Reminder #{reminder_label} before the appointment."
    }
  end

  defp handle_normalized_reminders([], meeting) do
    case legacy_reminder_label(meeting) do
      nil ->
        %{
          reminder_time: nil,
          default_reminder_time: nil,
          time_until: nil,
          time_until_friendly: nil,
          reminders_enabled: false,
          reminders_summary: "No reminder emails are scheduled for this appointment."
        }

      legacy_label ->
        %{
          reminder_time: legacy_label,
          default_reminder_time: legacy_label,
          time_until: legacy_label,
          time_until_friendly: "in #{legacy_label}",
          reminders_enabled: true,
          reminders_summary: "I'll send you a reminder #{legacy_label} before our appointment."
        }
    end
  end

  defp handle_normalized_reminders([reminder], _meeting) do
    reminder_label = ReminderUtils.format_reminder_label(reminder.value, reminder.unit)

    %{
      reminder_time: reminder_label,
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: "in #{reminder_label}",
      reminders_enabled: true,
      reminders_summary: "I'll send you a reminder #{reminder_label} before our appointment."
    }
  end

  defp handle_normalized_reminders(reminder_list, _meeting) do
    closest =
      Enum.min_by(reminder_list, fn %{value: value, unit: unit} ->
        ReminderUtils.reminder_interval_seconds(value, unit)
      end)

    reminder_label = ReminderUtils.format_reminder_label(closest.value, closest.unit)

    %{
      reminder_time: reminder_label,
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: "in #{reminder_label}",
      reminders_enabled: true,
      reminders_summary:
        "You'll receive #{length(reminder_list)} reminders before the appointment."
    }
  end

  defp format_location(meeting) do
    if meeting.meeting_url do
      "Video Call"
    else
      meeting.location || "To be determined"
    end
  end

  defp format_location_details(meeting) do
    if meeting.meeting_url do
      "Video Call"
    else
      meeting.location || "Location to be determined"
    end
  end

  defp convert_to_timezone(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} ->
        shifted

      {:error, reason} ->
        Logger.error("Timezone conversion failed for #{timezone}",
          reason: inspect(reason),
          datetime: datetime
        )

        datetime
    end
  end

  defp legacy_reminder_label(meeting) do
    meeting.reminder_time || meeting.default_reminder_time
  end
end
