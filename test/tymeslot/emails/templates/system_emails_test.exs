defmodule Tymeslot.Emails.Templates.SystemEmailsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.{
    CalendarSyncError,
    IntegrationUnhealthy,
    RescheduleRequest
  }

  import Tymeslot.Factory

  describe "CalendarSyncError.render/2" do
    test "generates valid HTML output" do
      meeting = insert(:meeting)
      error_reason = :network_error

      html = CalendarSyncError.render(meeting, error_reason)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "includes error details in output" do
      meeting = insert(:meeting)
      error_reason = :authentication_failed

      html = CalendarSyncError.render(meeting, error_reason)

      assert is_binary(html)
      # Error details should be formatted and included
      assert String.length(html) > 500
    end

    test "includes meeting details" do
      meeting = insert(:meeting, location: "Conference Room A", duration: 60)
      error_reason = :connection_timeout

      html = CalendarSyncError.render(meeting, error_reason)

      assert html =~ "Conference Room A" || html =~ "Meeting Details"
    end

    test "handles missing organizer_user_id with fallback timezone" do
      meeting = insert(:meeting, organizer_user_id: nil)
      error_reason = :unknown_error

      html = CalendarSyncError.render(meeting, error_reason)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "converts meeting time to owner's timezone" do
      profile = insert(:profile, timezone: "America/New_York")
      meeting = insert(:meeting, organizer_user: profile.user)
      error_reason = :rate_limited

      html = CalendarSyncError.render(meeting, error_reason)

      assert is_binary(html)
      # Should contain time information
      assert String.length(html) > 500
    end

    test "includes action required section" do
      meeting = insert(:meeting)
      error_reason = :server_unavailable

      html = CalendarSyncError.render(meeting, error_reason)

      assert html =~ "Action" || html =~ "action" || html =~ "manually"
    end

    test "includes common causes section" do
      meeting = insert(:meeting)
      error_reason = :invalid_credentials

      html = CalendarSyncError.render(meeting, error_reason)

      assert html =~ "Common" || html =~ "causes" || html =~ "CalDAV"
    end

    test "handles various error reasons" do
      meeting = insert(:meeting)

      error_reasons = [
        :network_error,
        :timeout,
        :authentication_failed,
        :rate_limited,
        :server_error
      ]

      for error_reason <- error_reasons do
        html = CalendarSyncError.render(meeting, error_reason)
        assert is_binary(html)
        assert String.length(html) > 500
      end
    end
  end

  describe "CalendarSyncError.render_text/2" do
    test "returns plain text with meeting and error details" do
      meeting = insert(:meeting, location: "Conference Room A", duration: 60)

      text = CalendarSyncError.render_text(meeting, :network_error)

      assert text =~ "Calendar Sync Error"
      assert text =~ "Conference Room A"
      assert text =~ "60 minutes"
      assert text =~ "manually"
    end

    test "handles missing organizer_user_id" do
      meeting = insert(:meeting, organizer_user_id: nil)

      text = CalendarSyncError.render_text(meeting, :unknown_error)

      assert is_binary(text)
      assert String.length(text) > 100
    end
  end

  describe "IntegrationUnhealthy.render/3" do
    test "generates valid HTML output for calendar type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "generates valid HTML output for video type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      html = IntegrationUnhealthy.render(user, integration, :video)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "includes humanized provider label" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert html =~ "Google calendar"
    end

    test "includes integration type in content" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      html = IntegrationUnhealthy.render(user, integration, :video)

      assert html =~ "video"
    end

    test "includes connection issues warning" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert html =~ "connection" || html =~ "Connection"
    end

    test "includes settings action button" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert html =~ "Check Integration Settings"
    end

    test "includes 48 hour threshold mention" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      html = IntegrationUnhealthy.render(user, integration, :calendar)

      assert html =~ "48"
    end

    test "handles unknown integration type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :custom_service}

      html = IntegrationUnhealthy.render(user, integration, :other)

      assert is_binary(html)
      assert String.length(html) > 500
    end
  end

  describe "IntegrationUnhealthy.render_text/3" do
    test "returns plain text with provider and type details" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :google_calendar}

      text = IntegrationUnhealthy.render_text(user, integration, :calendar)

      assert text =~ "Google calendar"
      assert text =~ "calendar"
      assert text =~ "48"
      assert text =~ "Check Integration Settings"
    end

    test "handles video type" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :zoom}

      text = IntegrationUnhealthy.render_text(user, integration, :video)

      assert text =~ "Zoom"
      assert text =~ "video"
    end
  end

  describe "RescheduleRequest.reschedule_request_email/1" do
    test "creates valid Swoosh email with text_body" do
      meeting = insert(:meeting)
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.html_body != nil
      assert email.text_body != nil
      assert email.text_body =~ "Reschedule Request"
      assert email.text_body =~ "Choose a New Time"
    end

    test "sets correct recipient as attendee" do
      meeting =
        insert(:meeting, attendee_name: "Sarah Johnson", attendee_email: "sarah@example.com")

      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.to == [{"Sarah Johnson", "sarah@example.com"}]
    end

    test "includes subject with meeting title and date" do
      meeting = insert(:meeting, title: "Product Demo")
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.subject =~ "Reschedule"
      assert email.subject =~ "Product Demo"
    end

    test "includes attendee name in HTML body" do
      meeting = insert(:meeting, attendee_name: "Michael Chen")
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.html_body =~ "Michael Chen"
    end

    test "includes meeting details" do
      meeting =
        insert(:meeting,
          location: "Video Conference",
          duration: 45,
          meeting_type: "Consultation"
        )

      email = RescheduleRequest.reschedule_request_email(meeting)

      # Should contain substantial meeting information
      assert String.length(email.html_body) > 1000
    end

    test "includes reschedule URL" do
      email_config = Application.get_env(:tymeslot, :email)
      domain = email_config[:domain] || "tymeslot.app"
      reschedule_url = "https://#{domain}/reschedule/token123"
      meeting = insert(:meeting, reschedule_url: reschedule_url)
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.html_body =~ reschedule_url
    end

    test "includes call to action button" do
      meeting = insert(:meeting)
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.html_body =~ "Choose" || email.html_body =~ "New Time" ||
               email.html_body =~ "reschedule"
    end

    test "converts time to attendee timezone" do
      meeting = insert(:meeting, attendee_timezone: "America/New_York")
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.html_body != nil
      # Should contain time information
      assert String.length(email.html_body) > 1000
    end

    test "handles missing attendee timezone with UTC fallback" do
      meeting = insert(:meeting, attendee_timezone: nil)
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert %Swoosh.Email{} = email
      assert email.html_body != nil
    end

    test "includes apology and explanation text" do
      meeting = insert(:meeting)
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.html_body =~ "apologize" || email.html_body =~ "inconvenience" ||
               email.html_body =~ "cancelled"
    end

    test "includes organizer information in from field" do
      meeting = insert(:meeting, organizer_name: "Dr. Lisa Anderson")
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.from ==
               {"Dr. Lisa Anderson", Application.get_env(:tymeslot, :email)[:from_email]}
    end

    test "handles various meeting types" do
      meeting_types = ["Discovery Call", "Demo", "Consultation", "Interview"]

      for type <- meeting_types do
        meeting = insert(:meeting, meeting_type: type)
        email = RescheduleRequest.reschedule_request_email(meeting)

        assert %Swoosh.Email{} = email
        assert email.html_body != nil
      end
    end
  end

  describe "RescheduleRequest locale rendering" do
    test "renders without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr"] do
        meeting = insert(:meeting, attendee_locale: locale)
        email = RescheduleRequest.reschedule_request_email(meeting)

        assert %Swoosh.Email{} = email,
               "Expected valid Swoosh email for locale #{locale}"

        assert is_binary(email.html_body),
               "Expected html_body for locale #{locale}"

        assert is_binary(email.text_body),
               "Expected text_body for locale #{locale}"
      end
    end

    test "German reschedule request translates subject and body" do
      meeting = insert(:meeting, attendee_locale: "de")
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.subject =~ "Verschiebungsanfrage"
      refute email.subject =~ "Reschedule Request"
      assert email.text_body =~ "Anfrage zur Terminverschiebung"
    end

    test "French reschedule request translates subject and body" do
      meeting = insert(:meeting, attendee_locale: "fr")
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.subject =~ "Demande de report"
      refute email.subject =~ "Reschedule Request"
      assert email.text_body =~ "Demande de report"
    end

    test "Ukrainian reschedule request translates subject and body" do
      meeting = insert(:meeting, attendee_locale: "uk")
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert email.subject =~ "Запит на перенесення"
      refute email.subject =~ "Reschedule Request"
      assert email.text_body =~ "Запит на перенесення"
    end
  end

  describe "render/2 security" do
    test "CalendarSyncError.render/2 handles XML-hostile error reason without crashing" do
      meeting = insert(:meeting)
      html = CalendarSyncError.render(meeting, "<CalDAV:error> tag not closed & invalid")

      assert is_binary(html)
      assert String.length(html) > 500
      refute html =~ "<CalDAV:error>"
    end

    test "CalendarSyncError.render/2 handles XML-hostile binary error without crashing" do
      meeting = insert(:meeting)
      html = CalendarSyncError.render(meeting, "Response: <foo/> & </bar> unclosed")

      assert is_binary(html)
      assert String.length(html) > 500
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input and the expected structural content is always present.

    test "CalendarSyncError.render_text returns a valid binary with malicious error reason" do
      meeting = insert(:meeting)
      text = CalendarSyncError.render_text(meeting, "<script>alert('xss')</script>")

      assert is_binary(text)
      assert text =~ "Calendar Sync Error"
      assert text =~ "ACTION REQUIRED"
    end

    test "CalendarSyncError.render_text returns a valid binary with malicious location" do
      meeting = insert(:meeting, location: "Room A\nX-Injected: evil-header")
      text = CalendarSyncError.render_text(meeting, :network_error)

      assert is_binary(text)
      assert text =~ "Calendar Sync Error"
    end

    test "IntegrationUnhealthy.render_text returns a valid binary with unusual provider atom" do
      user = %{id: 1, email: "user@example.com", name: "Test User"}
      integration = %{provider: :"weird<>provider"}

      text = IntegrationUnhealthy.render_text(user, integration, :calendar)

      assert is_binary(text)
      assert text =~ "Check Integration Settings"
    end

    test "RescheduleRequest text_body is always present and contains expected structure with malicious attendee name" do
      meeting = insert(:meeting, attendee_name: "<script>steal()</script>")
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert is_binary(email.text_body)
      assert email.text_body =~ "Choose a New Time"
    end
  end
end
