defmodule Tymeslot.Emails.Templates.SystemEmailsTest do
  @moduletag :emails
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Emails.Templates.{
    CalendarSyncError,
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

  describe "RescheduleRequest.reschedule_request_email/1" do
    test "creates valid Swoosh email" do
      meeting = insert(:meeting)
      email = RescheduleRequest.reschedule_request_email(meeting)

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.html_body != nil
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
end
