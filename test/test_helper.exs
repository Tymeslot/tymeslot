# Configure Swoosh for testing
Application.put_env(:swoosh, :api_client, false)
Application.put_env(:tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Test)

# Enable test mode to skip sleep calls in workers
Application.put_env(:tymeslot, :test_mode, true)

# Start required applications
Application.ensure_all_started(:tzdata)

# Run migrations before tests
Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet"])

# Start Ecto sandbox - ensure Repo is ready first
{:ok, _} = Application.ensure_all_started(:tymeslot)
Ecto.Adapters.SQL.Sandbox.mode(Tymeslot.Repo, :manual)

# Start RateLimiter for tests
{:ok, _} = Tymeslot.Security.RateLimiter.start_link()
# Start AccountLockout for tests
{:ok, _} = Tymeslot.Security.AccountLockout.start_link()

# Define mocks
Mox.defmock(Tymeslot.CalendarMock,
  for: Tymeslot.Integrations.Calendar.CalendarBehaviour
)

Mox.defmock(Tymeslot.MiroTalkAPIMock,
  for: Tymeslot.Integrations.Video.MiroTalk.MiroTalkClientBehaviour
)

Mox.defmock(Tymeslot.RadicaleClientMock,
  for: Tymeslot.Integrations.Calendar.CalDAV.ClientBehaviour
)

Mox.defmock(Tymeslot.EmailServiceMock, for: Tymeslot.Emails.EmailServiceBehaviour)
Mox.defmock(Tymeslot.HTTPClientMock, for: Tymeslot.Infrastructure.HTTPClientBehaviour)
Mox.defmock(Tymeslot.GoogleOAuthHelperMock,
  for: Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
)

Mox.defmock(Tymeslot.OutlookOAuthHelperMock,
  for: Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
)

Mox.defmock(GoogleCalendarAPIMock,
  for: Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour
)

Mox.defmock(OutlookCalendarAPIMock,
  for: Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour
)

ExUnit.start(exclude: [:backup_tests, :oauth_integration, :calendar_integration])

# Configure ExUnit to exclude backup tests, OAuth integration tests, and calendar
# integration tests by default. Integration tests now run by default.
ExUnit.configure(
  exclude: [
    backup_tests: true,
    oauth_integration: true,
    calendar_integration: true
  ]
)

# Helper functions for tests
defmodule Tymeslot.TestHelpers do
  @moduledoc """
  Test helper functions and utilities
  """

  @spec sample_appointment_data() :: map()
  def sample_appointment_data do
    %{
      uid: "test-appointment-123",
      organizer_name: "Luka Breitig",
      organizer_email: "luka@example.com",
      organizer_title: "CEO",
      attendee_name: "Jane Doe",
      attendee_email: "jane@example.com",
      attendee_phone: "+1-555-123-4567",
      attendee_company: "Test Company",
      attendee_message: "Looking forward to our discussion about the project.",
      date: ~D[2024-02-15],
      start_time: ~U[2024-02-15 14:00:00Z],
      end_time: ~U[2024-02-15 15:00:00Z],
      start_time_owner_tz: ~U[2024-02-15 16:00:00Z],
      end_time_owner_tz: ~U[2024-02-15 17:00:00Z],
      attendee_timezone: "America/New_York",
      start_time_attendee_tz: ~U[2024-02-15 09:00:00Z],
      end_time_attendee_tz: ~U[2024-02-15 10:00:00Z],
      duration: 60,
      location: "Conference Room A",
      location_details: "Conference Room A - 2nd Floor",
      meeting_type: "Project Discussion",
      meeting_url: "https://app.example.com/appointments/123/join",
      what_to_expect: "We'll discuss project goals and timeline.",
      preparation_notes: "Please bring project documents.",
      preparation_reminder: "Don't forget to review the agenda!",
      default_reminder_time: "15 minutes",
      custom_checklist: ["Review agenda", "Prepare questions"],
      what_to_bring: ["Project documents", "Laptop"],
      organizer_contact_info: "Phone: +1-555-000-0000",
      contact_info: "For questions, call +1-555-000-0000",
      allow_contact: true,
      reminder_time: "15 minutes",
      time_until_friendly: "fifteen minutes",
      view_url: "https://app.example.com/appointments/123",
      reschedule_url: "https://app.example.com/appointments/123/reschedule",
      cancel_url: "https://app.example.com/appointments/123/cancel"
    }
  end
end
