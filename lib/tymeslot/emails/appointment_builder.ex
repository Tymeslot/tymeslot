defmodule Tymeslot.Emails.AppointmentBuilder do
  @moduledoc """
  Builds appointment details payloads for email templates and delivery adapters.
  Extracted from EmailWorker to keep the worker focused on orchestration.
  """

  require Logger
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.ReminderUtils

  use Gettext, backend: TymeslotWeb.Gettext

  @default_timezone Profiles.get_default_timezone()

  @spec from_meeting(map(), map() | nil) :: Tymeslot.Emails.EmailService.appointment_details()
  def from_meeting(meeting, reminder_interval \\ nil) do
    attendee_locale = Map.get(meeting, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, attendee_locale, fn ->
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
      |> Map.put(:attendee_locale, attendee_locale)
      |> Map.put(:booking_payment, booking_payment_for(meeting))
    end)
  end

  # Look up the booking payment row attached to this meeting, if any.
  # Free bookings have no booking_payment row, so this returns nil and the
  # email template short-circuits the receipt block.
  defp booking_payment_for(%{id: meeting_id}) when is_binary(meeting_id),
    do: MeetingPayments.payment_for_meeting(meeting_id)

  defp booking_payment_for(_meeting), do: nil

  defp owner_timezone(meeting) do
    case meeting.organizer_user_id do
      nil ->
        Logger.error("Missing organizer_user_id for meeting, using default timezone",
          meeting_uid: meeting.uid
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
          "Missing attendee_timezone for meeting, using organizer timezone as emergency fallback",
          meeting_uid: meeting.uid
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
      location_type: determine_location_type(meeting),
      location_details: format_location_details(meeting),
      meeting_type: meeting.meeting_type,
      ical_sequence: Map.get(meeting, :ical_sequence) || 0,
      custom_fields_snapshot: Map.get(meeting, :custom_fields_snapshot) || [],
      custom_field_answers: Map.get(meeting, :custom_field_answers) || %{}
    }
  end

  defp determine_location_type(meeting) do
    cond do
      meeting.meeting_url -> :video
      meeting.location == "Phone Call" -> :phone
      meeting.location == "In Person" -> :in_person
      true -> :custom
    end
  end

  defp timezone_details(meeting, owner_timezone, attendee_timezone) do
    %{
      attendee_timezone: attendee_timezone,
      start_time_owner_tz: DateTimeUtils.convert_to_timezone(meeting.start_time, owner_timezone),
      end_time_owner_tz: DateTimeUtils.convert_to_timezone(meeting.end_time, owner_timezone),
      start_time_attendee_tz:
        DateTimeUtils.convert_to_timezone(meeting.start_time, attendee_timezone),
      end_time_attendee_tz: DateTimeUtils.convert_to_timezone(meeting.end_time, attendee_timezone)
    }
  end

  defp participant_details(meeting) do
    %{
      # Organizer details
      organizer_name: meeting.organizer_name,
      organizer_email: meeting.organizer_email,
      organizer_title: meeting.organizer_title,
      organizer_contact_info: dgettext("emails", "reply to this email"),

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
      contact_info: dgettext("emails", "reply to this email"),
      allow_contact: true,
      time_until_friendly: dgettext("emails", "in 30 minutes")
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
    reminder_label = localized_reminder_label(value, unit)

    %{
      reminder_time: reminder_label,
      reminder_raw: %{value: value, unit: unit},
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: dgettext("emails", "in %{label}", label: reminder_label),
      reminders_enabled: true,
      reminders_summary:
        dgettext("emails", "Reminder %{label} before the appointment.", label: reminder_label)
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
          reminders_summary:
            dgettext("emails", "No reminder emails are scheduled for this appointment.")
        }

      legacy_label ->
        %{
          reminder_time: legacy_label,
          default_reminder_time: legacy_label,
          time_until: legacy_label,
          time_until_friendly: dgettext("emails", "in %{label}", label: legacy_label),
          reminders_enabled: true,
          reminders_summary:
            dgettext("emails", "I'll send you a reminder %{label} before our appointment.",
              label: legacy_label
            )
        }
    end
  end

  defp handle_normalized_reminders([reminder], _meeting) do
    reminder_label = localized_reminder_label(reminder.value, reminder.unit)

    %{
      reminder_time: reminder_label,
      reminder_raw: %{value: reminder.value, unit: reminder.unit},
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: dgettext("emails", "in %{label}", label: reminder_label),
      reminders_enabled: true,
      reminders_summary:
        dgettext("emails", "I'll send you a reminder %{label} before our appointment.",
          label: reminder_label
        )
    }
  end

  defp handle_normalized_reminders(reminder_list, _meeting) do
    closest =
      Enum.min_by(reminder_list, fn %{value: value, unit: unit} ->
        ReminderUtils.reminder_interval_seconds(value, unit)
      end)

    reminder_label = localized_reminder_label(closest.value, closest.unit)

    %{
      reminder_time: reminder_label,
      reminder_raw: %{value: closest.value, unit: closest.unit},
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: dgettext("emails", "in %{label}", label: reminder_label),
      reminders_enabled: true,
      reminders_summary:
        dngettext(
          "emails",
          "You'll receive %{count} reminder before the appointment.",
          "You'll receive %{count} reminders before the appointment.",
          length(reminder_list),
          count: length(reminder_list)
        )
    }
  end

  # Derive a display location from the meeting's fields. When a video URL is
  # present the location is "Video Call" regardless of any physical location
  # stored on the record. When nothing is set, return nil so the rendering
  # layer (`Formatting.format_location/1`) substitutes the localised "TBD".
  # Legacy meetings persisted the English placeholder before that change —
  # treat it as nil here so they also render translated.
  defp format_location(meeting) do
    cond do
      meeting.meeting_url -> "Video Call"
      meeting.location in [nil, "", "To be determined"] -> nil
      true -> meeting.location
    end
  end

  defp format_location_details(meeting), do: format_location(meeting)

  defp legacy_reminder_label(meeting) do
    meeting.reminder_time || meeting.default_reminder_time
  end

  # Formats a reminder label using locale-aware unit words.
  # Must be called from within a Gettext.with_locale block.
  defp localized_reminder_label(value, unit) do
    value = ReminderUtils.parse_reminder_value(value)
    unit = ReminderUtils.normalize_reminder_unit(unit)

    unit_word =
      case unit do
        "minutes" -> dngettext("emails", "minute", "minutes", value)
        "hours" -> dngettext("emails", "hour", "hours", value)
        "days" -> dngettext("emails", "day", "days", value)
        _other -> dngettext("emails", "minute", "minutes", value)
      end

    "#{value} #{unit_word}"
  end
end
