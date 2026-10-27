defmodule Tymeslot.Notifications.ContentBuilder do
  @moduledoc """
  The meeting details `Tymeslot.Meetings.CalendarExport` builds a calendar
  file from. Emails are built by `Tymeslot.Emails.AppointmentBuilder`.
  """

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Notifications.Recipients
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  Builds appointment details for email notifications.
  """
  @spec build_appointment_details(%{atom() => term()}) :: %{atom() => term()}
  def build_appointment_details(meeting) do
    organizer_timezone = Recipients.get_organizer_timezone(meeting)
    # Get attendee timezone - should always be present
    attendee_timezone = Recipients.get_attendee_timezone(meeting)
    links = MeetingLinks.for_meeting(meeting)

    %{
      # The calendar event's UID, as in `AppointmentBuilder`: never the
      # booking's capability-bearing `uid`.
      uid: meeting.calendar_uid,
      title: meeting.title,

      # Attendee information
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email,
      attendee_locale: RecipientLocale.attendee_locale(meeting),
      attendee_message: meeting.attendee_message || "",
      attendee_timezone: attendee_timezone,

      # Organizer information
      organizer_user_id: Map.get(meeting, :organizer_user_id),
      organizer_note: meeting.organizer_note,
      organizer_name: meeting.organizer_name,
      organizer_email: meeting.organizer_email,
      organizer_title: meeting.organizer_title,
      organizer_timezone: organizer_timezone,
      organizer_avatar_url: get_organizer_avatar_url(meeting),

      # Meeting timing
      date: meeting.start_time,
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      duration: meeting.duration,

      # Timezone-specific times
      start_time_owner_tz: convert_to_timezone(meeting.start_time, organizer_timezone),
      start_time_attendee_tz: convert_to_timezone(meeting.start_time, attendee_timezone),

      # Meeting details
      location: determine_location(meeting),
      meeting_type: meeting.meeting_type,

      # URLs and links
      view_url: links.view_url,
      reschedule_url: links.reschedule_url,
      cancel_url: links.cancel_url,

      # Video room information
      meeting_url: meeting.meeting_url,
      organizer_video_url: meeting.organizer_video_url,
      attendee_video_url: meeting.attendee_video_url,
      video_room_enabled: meeting.video_room_enabled || false,

      # Additional context
      created_at: meeting.inserted_at,
      updated_at: meeting.updated_at,

      # Default reminder time for email templates
      default_reminder_time: meeting.default_reminder_time || "30 minutes",
      reminder_time: meeting.reminder_time || meeting.default_reminder_time || "30 minutes",

      # Organizer contact info for email templates
      organizer_contact_info: build_organizer_contact_info(meeting)
    }
  end

  # Private functions

  defp determine_location(meeting) do
    cond do
      meeting.meeting_url -> "Video Call"
      meeting.location -> meeting.location
      true -> "TBD"
    end
  end

  defp convert_to_timezone(datetime, timezone) do
    DateTimeUtils.convert_to_timezone(datetime, timezone)
  end

  defp build_organizer_contact_info(meeting) do
    if meeting.organizer_title do
      "#{meeting.organizer_name}, #{meeting.organizer_title}"
    else
      meeting.organizer_name
    end
  end

  # Never the initials data URI `Profiles.avatar_url/2` falls back to: Gmail
  # refuses to render data URI images in email.
  defp get_organizer_avatar_url(meeting) do
    meeting |> get_organizer_profile() |> Profiles.uploaded_avatar_url()
  end

  defp get_organizer_profile(meeting) do
    cond do
      Map.has_key?(meeting, :organizer_user_id) && meeting.organizer_user_id ->
        get_profile_by_user_id(meeting.organizer_user_id)

      meeting.organizer_email ->
        get_profile_by_email(meeting.organizer_email)

      true ->
        nil
    end
  end

  defp get_profile_by_user_id(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} -> profile
      {:error, :not_found} -> nil
    end
  end

  defp get_profile_by_email(email) do
    case UserQueries.get_user_by_email(email) do
      {:error, :not_found} -> nil
      {:ok, user} -> get_profile_by_user_id(user.id)
    end
  end
end
