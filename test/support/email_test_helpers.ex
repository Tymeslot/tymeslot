defmodule Tymeslot.EmailTestHelpers do
  @moduledoc """
  Helper functions for email testing.

  Provides factory functions to build test data for email templates,
  ensuring consistent test data across all email-related tests.
  """

  alias Tymeslot.Emails.Shared.SharedHelpers

  @doc """
  Builds appointment details map for testing email templates.

  ## Options

    * `:uid` - Meeting UID (default: auto-generated)
    * `:title` - Meeting title (default: "Test Meeting")
    * `:organizer_name` - Organizer full name (default: "John Organizer")
    * `:organizer_email` - Organizer email (default: "organizer@example.com")
    * `:organizer_title` - Organizer title (default: "Product Manager")
    * `:attendee_name` - Attendee full name (default: "Jane Attendee")
    * `:attendee_email` - Attendee email (default: "attendee@example.com")
    * `:attendee_phone` - Attendee phone (default: "+1-555-0123")
    * `:attendee_company` - Attendee company (default: "Acme Corp")
    * `:attendee_message` - Attendee message (default: "Looking forward to discussing the project")
    * `:date` - Meeting date (default: 2026-01-15)
    * `:start_time` - Start datetime UTC (default: 2026-01-15 14:00:00Z)
    * `:end_time` - End datetime UTC (default: 2026-01-15 15:00:00Z)
    * `:start_time_owner_tz` - Start datetime in organizer TZ (default: same as start_time)
    * `:end_time_owner_tz` - End datetime in organizer TZ (default: same as end_time)
    * `:start_time_attendee_tz` - Start datetime in attendee TZ (default: same as start_time)
    * `:end_time_attendee_tz` - End datetime in attendee TZ (default: same as end_time)
    * `:duration` - Duration in minutes (default: 60)
    * `:location` - Location (default: "Virtual Meeting")
    * `:meeting_type` - Meeting type (default: "Discovery Call")
    * `:reschedule_url` - Reschedule URL (default: generated)
    * `:cancel_url` - Cancel URL (default: generated)
    * `:meeting_url` - Video meeting URL (default: generated)
    * `:organizer_video_url` - Organizer video URL (default: generated)
    * `:attendee_video_url` - Attendee video URL (default: generated)
    * `:view_url` - View meeting URL (default: generated)
    * `:reminder_time` - Reminder time text (default: "30 minutes")
    * `:time_until` - Time until meeting (default: "30 minutes")

  ## Examples

      iex> build_appointment_details()
      %{uid: "test-uid-...", organizer_email: "organizer@example.com", ...}

      iex> build_appointment_details(%{organizer_email: "custom@example.com"})
      %{uid: "test-uid-...", organizer_email: "custom@example.com", ...}

  """
  @spec build_appointment_details(map()) :: map()
  def build_appointment_details(overrides \\ %{}) do
    uid = Map.get(overrides, :uid, "test-uid-#{System.unique_integer([:positive])}")
    base_url = "https://tymeslot.example.com"

    defaults = %{
      uid: uid,
      title: "Test Meeting",
      summary: "Test Meeting Summary",
      description: "Test meeting description with details",
      organizer_name: "John Organizer",
      organizer_email: "organizer@example.com",
      organizer_title: "Product Manager",
      organizer_avatar_url: nil,
      organizer_contact_info: "Contact me anytime",
      attendee_name: "Jane Attendee",
      attendee_email: "attendee@example.com",
      attendee_phone: "+1-555-0123",
      attendee_company: "Acme Corp",
      attendee_message: "Looking forward to discussing the project",
      date: ~D[2026-01-15],
      start_time: ~U[2026-01-15 14:00:00Z],
      end_time: ~U[2026-01-15 15:00:00Z],
      start_time_owner_tz: ~U[2026-01-15 14:00:00Z],
      end_time_owner_tz: ~U[2026-01-15 15:00:00Z],
      start_time_attendee_tz: ~U[2026-01-15 14:00:00Z],
      end_time_attendee_tz: ~U[2026-01-15 15:00:00Z],
      attendee_timezone: "America/New_York",
      duration: 60,
      location: "Virtual Meeting",
      meeting_type: "Discovery Call",
      reschedule_url: "#{base_url}/reschedule/#{uid}",
      cancel_url: "#{base_url}/cancel/#{uid}",
      meeting_url: "https://meet.example.com/#{uid}",
      organizer_video_url: "https://meet.example.com/#{uid}?role=host",
      attendee_video_url: "https://meet.example.com/#{uid}?role=guest",
      view_url: "#{base_url}/meetings/#{uid}",
      reminder_time: "30 minutes",
      time_until: "30 minutes",
      time_until_friendly: "in 30 minutes",
      default_reminder_time: "15 minutes"
    }

    Map.merge(defaults, overrides)
  end

  @doc """
  Builds minimal appointment details for simpler tests.
  """
  @spec build_minimal_appointment_details(map()) :: map()
  def build_minimal_appointment_details(overrides \\ %{}) do
    Map.merge(
      %{
        uid: "minimal-#{System.unique_integer([:positive])}",
        organizer_name: "Organizer",
        organizer_email: "organizer@test.com",
        attendee_name: "Attendee",
        attendee_email: "attendee@test.com",
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        duration: 60
      },
      overrides
    )
  end

  @doc """
  Formats a date using SharedHelpers for consistent test assertions.
  """
  @spec format_date_short(Date.t()) :: String.t()
  def format_date_short(date) do
    SharedHelpers.format_date_short(date)
  end

  @doc """
  Formats a time using SharedHelpers for consistent test assertions.
  """
  @spec format_time(DateTime.t()) :: String.t()
  def format_time(datetime) do
    SharedHelpers.format_time(datetime)
  end

  @doc """
  Builds user data for authentication email tests.
  """
  @spec build_user_data(map()) :: map()
  def build_user_data(overrides \\ %{}) do
    defaults = %{
      id: System.unique_integer([:positive]),
      email: "user@example.com",
      name: "Test User",
      full_name: "Test User",
      username: "testuser",
      email_verified: false,
      email_verified_at: nil
    }

    Map.merge(defaults, overrides)
  end

  @doc """
  Builds verification data for email verification tests.
  """
  @spec build_verification_data(map()) :: map()
  def build_verification_data(overrides \\ %{}) do
    token = "test-verification-token-#{System.unique_integer([:positive])}"

    defaults = %{
      token: token,
      email: "verify@example.com",
      verification_url: "https://tymeslot.example.com/verify/#{token}"
    }

    Map.merge(defaults, overrides)
  end

  @doc """
  Builds password reset data for password reset email tests.
  """
  @spec build_password_reset_data(map()) :: map()
  def build_password_reset_data(overrides \\ %{}) do
    token = "test-reset-token-#{System.unique_integer([:positive])}"

    defaults = %{
      token: token,
      email: "reset@example.com",
      reset_url: "https://tymeslot.example.com/password-reset/#{token}"
    }

    Map.merge(defaults, overrides)
  end

  @doc """
  Builds email change data for email change email tests.
  """
  @spec build_email_change_data(map()) :: map()
  def build_email_change_data(overrides \\ %{}) do
    token = "test-change-token-#{System.unique_integer([:positive])}"

    defaults = %{
      token: token,
      old_email: "old@example.com",
      new_email: "new@example.com",
      verification_url: "https://tymeslot.example.com/email-change/verify/#{token}"
    }

    Map.merge(defaults, overrides)
  end
end
