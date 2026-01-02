defmodule Tymeslot.Notifications.ContentBuilder do
  @moduledoc """
  Builds notification content and email data structures.
  Pure functions for converting meeting data into notification-ready formats.
  """

  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Notifications.Recipients
  alias Tymeslot.Profiles

  @doc """
  Builds appointment details for email notifications.
  """
  @spec build_appointment_details(map()) :: map()
  def build_appointment_details(meeting) do
    organizer_timezone = Recipients.get_organizer_timezone(meeting)
    # Get attendee timezone - should always be present
    attendee_timezone = Recipients.get_attendee_timezone(meeting)

    %{
      # Meeting identification
      uid: meeting.uid,
      title: meeting.title,

      # Attendee information
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email,
      attendee_message: meeting.attendee_message || "",
      attendee_timezone: attendee_timezone,

      # Organizer information
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
      view_url: meeting.view_url,
      reschedule_url: meeting.reschedule_url,
      cancel_url: meeting.cancel_url,

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

  @doc """
  Builds cancellation details for email notifications.
  """
  @spec build_cancellation_details(map()) :: map()
  def build_cancellation_details(meeting) do
    organizer_timezone = Recipients.get_organizer_timezone(meeting)

    %{
      # Meeting identification
      uid: meeting.uid,
      title: meeting.title,

      # Participant information
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email,
      organizer_name: meeting.organizer_name,
      organizer_email: meeting.organizer_email,
      organizer_title: meeting.organizer_title,

      # Meeting timing
      date: meeting.start_time,
      start_time: meeting.start_time,
      start_time_owner_tz: convert_to_timezone(meeting.start_time, organizer_timezone),
      duration: meeting.duration,

      # Meeting details
      location: meeting.location,
      meeting_type: meeting.meeting_type,

      # Cancellation context
      cancelled_at: meeting.cancelled_at || DateTime.utc_now(),
      cancellation_reason: meeting.cancellation_reason
    }
  end

  @doc """
  Builds reschedule details for email notifications.
  """
  @spec build_reschedule_details(map(), map()) :: map()
  def build_reschedule_details(updated_meeting, original_meeting) do
    organizer_timezone = Recipients.get_organizer_timezone(updated_meeting)

    base_details = build_appointment_details(updated_meeting)

    Map.merge(base_details, %{
      # Original meeting details for comparison
      original_date: original_meeting.start_time,
      original_start_time: original_meeting.start_time,
      original_start_time_owner_tz:
        convert_to_timezone(original_meeting.start_time, organizer_timezone),
      original_end_time: original_meeting.end_time,

      # Reschedule context
      is_rescheduled: true,
      rescheduled_at: DateTime.utc_now()
    })
  end

  @doc """
  Builds video room notification details.
  """
  @spec build_video_room_details(map(), atom()) :: map()
  def build_video_room_details(meeting, video_room_status) do
    base_details = build_appointment_details(meeting)

    Map.merge(base_details, %{
      video_room_status: video_room_status,
      video_room_created_at: meeting.video_room_created_at,
      video_room_expires_at: meeting.video_room_expires_at
    })
  end

  @doc """
  Builds reminder notification details.
  """
  @spec build_reminder_details(map()) :: map()
  def build_reminder_details(meeting) do
    base_details = build_appointment_details(meeting)

    reminder_time =
      Keyword.get(Application.get_env(:tymeslot, :notifications, []), :reminder_minutes, 30)

    Map.merge(base_details, %{
      is_reminder: true,
      reminder_time: "#{reminder_time} minutes"
    })
  end

  @doc """
  Builds email subject line for notification type.
  """
  @spec build_subject(atom(), map()) :: String.t()
  def build_subject(notification_type, meeting) do
    case notification_type do
      :confirmation ->
        "Meeting Confirmed: #{meeting.title}"

      :reminder ->
        "Meeting Reminder: #{meeting.title} in 30 minutes"

      :cancellation ->
        "Meeting Cancelled: #{meeting.title}"

      :reschedule ->
        "Meeting Rescheduled: #{meeting.title}"

      :video_room_created ->
        "Video Room Ready: #{meeting.title}"

      :video_room_failed ->
        "Video Room Issue: #{meeting.title}"

      _ ->
        "Meeting Update: #{meeting.title}"
    end
  end

  @doc """
  Validates that notification content is complete.
  """
  @spec validate_content(map()) :: :ok | {:error, String.t()}
  def validate_content(content) do
    required_fields = [
      :uid,
      :attendee_name,
      :attendee_email,
      :organizer_name,
      :organizer_email,
      :start_time
    ]

    missing_fields =
      Enum.reject(required_fields, fn field -> Map.has_key?(content, field) and content[field] end)

    case missing_fields do
      [] -> :ok
      fields -> {:error, "Missing content fields: #{Enum.join(fields, ", ")}"}
    end
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
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _} -> datetime
    end
  end

  defp build_organizer_contact_info(meeting) do
    if meeting.organizer_title do
      "#{meeting.organizer_name}, #{meeting.organizer_title}"
    else
      meeting.organizer_name
    end
  end

  defp get_organizer_avatar_url(meeting) do
    # Try to get the organizer's profile to fetch their avatar
    case get_organizer_profile(meeting) do
      nil -> nil
      profile -> Profiles.avatar_url(profile, :thumb)
    end
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
