defmodule Tymeslot.EmailTesting.Helpers do
  @moduledoc """
  Helper functions used across email template testing modules.
  """

  @doc "Build a comprehensive appointment details map used by various email templates"
  @spec build_appointment_details(String.t(), DateTime.t()) :: map()
  def build_appointment_details(email, start_time) do
    %{
      # Core required fields
      organizer_name: "Test Organizer",
      organizer_email: email,
      organizer_title: "Test Title",
      attendee_name: "Test Attendee",
      attendee_email: email,
      attendee_timezone: "America/New_York",
      title: "Test Meeting",

      # Time fields
      date: start_time,
      start_time: start_time,
      start_time_attendee_tz: start_time,
      start_time_organizer_tz: start_time,
      start_time_owner_tz: start_time,
      start_datetime: start_time,
      end_time: DateTime.add(start_time, 1800, :second),
      end_datetime: DateTime.add(start_time, 1800, :second),

      # Duration as integer
      duration: 30,

      # Location and meeting details
      location: "Video Call",
      meeting_type: "Debug Test",
      timezone: "UTC",
      company: "Test Company",
      description: "Testing email templates",

      # URLs
      meeting_url: "https://example.com/meeting",
      reschedule_url: "https://example.com/reschedule",
      cancel_url: "https://example.com/cancel",
      view_url: "https://example.com/view",

      # Video URLs for organizer and attendee
      organizer_video_url: "https://example.com/video/organizer",
      attendee_video_url: "https://example.com/video/attendee",

      # Additional optional fields
      reminder_time: "24 hours",
      default_reminder_time: "15 minutes",
      organizer_contact_info: "Contact: test@example.com",
      attendee_message: "Looking forward to our meeting",

      # ICS generation fields
      uid: "test-#{:rand.uniform(10000)}"
    }
  end

  @doc "Return a user-friendly adapter name"
  @spec get_adapter_name(module() | nil) :: String.t()
  def get_adapter_name(Swoosh.Adapters.Postmark), do: "Postmark"
  def get_adapter_name(Swoosh.Adapters.Local), do: "Local (Development)"
  def get_adapter_name(Swoosh.Adapters.SMTP), do: "SMTP"
  def get_adapter_name(Swoosh.Adapters.Sendgrid), do: "SendGrid"
  def get_adapter_name(Swoosh.Adapters.Mailgun), do: "Mailgun"
  def get_adapter_name(nil), do: "Not configured"
  def get_adapter_name(other), do: inspect(other)
end
