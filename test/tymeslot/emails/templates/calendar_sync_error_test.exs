defmodule Tymeslot.Emails.Templates.CalendarSyncErrorTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Emails.Templates.CalendarSyncError
  alias Tymeslot.Profiles

  import Tymeslot.Factory

  describe "CalendarSyncError.render/2" do
    test "generates valid HTML output" do
      meeting = insert(:meeting)
      error_reason = :network_error

      html = CalendarSyncError.render(meeting, error_reason)

      assert html =~ "</html>"
      assert html =~ "Calendar Sync Error"
      assert html =~ "Meeting Details"
    end

    test "includes error details in output" do
      meeting = insert(:meeting)
      error_reason = :authentication_failed

      html = CalendarSyncError.render(meeting, error_reason)

      assert html =~ "Error Details"
      assert html =~ ":authentication_failed"
    end

    test "includes meeting details" do
      meeting = insert(:meeting, location: "Conference Room A", duration: 60)
      error_reason = :connection_timeout

      html = CalendarSyncError.render(meeting, error_reason)

      assert html =~ "Conference Room A"
    end

    test "handles missing organizer_user_id with fallback timezone" do
      meeting = insert(:meeting, organizer_user_id: nil)
      error_reason = :unknown_error

      html = CalendarSyncError.render(meeting, error_reason)

      # Falls back to the application default timezone rather than crashing
      fallback_local = DateTime.shift_zone!(meeting.start_time, Profiles.get_default_timezone())

      assert html =~ Formatting.format_time(fallback_local, "en")
      assert html =~ "Calendar Sync Error"
    end

    test "converts meeting time to owner's timezone" do
      profile = insert(:profile, timezone: "America/New_York")
      meeting = insert(:meeting, organizer_user: profile.user)
      error_reason = :rate_limited

      html = CalendarSyncError.render(meeting, error_reason)

      owner_local = DateTime.shift_zone!(meeting.start_time, "America/New_York")

      assert html =~ Formatting.format_time(owner_local, "en")
      refute html =~ Formatting.format_time(meeting.start_time, "en")
    end

    test "includes action required section" do
      meeting = insert(:meeting)
      error_reason = :server_unavailable

      html = CalendarSyncError.render(meeting, error_reason)

      assert html =~ "Action Required"
    end

    test "includes common causes section" do
      meeting = insert(:meeting)
      error_reason = :invalid_credentials

      html = CalendarSyncError.render(meeting, error_reason)

      assert html =~ "Common causes:"
    end

    test "renders each error reason into the error details section" do
      meeting = insert(:meeting)

      error_reasons = [
        {:network_error, ":network_error"},
        {:timeout, ":timeout"},
        {:authentication_failed, ":authentication_failed"},
        {:rate_limited, ":rate_limited"},
        {:server_error, ":server_error"}
      ]

      for {error_reason, rendered} <- error_reasons do
        html = CalendarSyncError.render(meeting, error_reason)

        assert html =~ "Error Details"
        assert html =~ rendered
      end
    end
  end

  describe "CalendarSyncError.render_both/2" do
    test "returns a {html, text} tuple equivalent to calling render/2 and render_text/2 separately" do
      meeting = insert(:meeting)
      error_reason = :network_error

      {html, text} = CalendarSyncError.render_both(meeting, error_reason)

      assert html == CalendarSyncError.render(meeting, error_reason)
      assert text == CalendarSyncError.render_text(meeting, error_reason)
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

      assert text =~ "Calendar Sync Error"
      assert text =~ ":unknown_error"
      assert text =~ "Duration: #{meeting.duration} minutes"
    end
  end

  describe "render/2 security" do
    test "CalendarSyncError.render/2 handles XML-hostile error reason without crashing" do
      meeting = insert(:meeting)
      html = CalendarSyncError.render(meeting, "<CalDAV:error> tag not closed & invalid")

      assert html =~ "</html>"
      assert html =~ "Error Details"
      refute html =~ "<CalDAV:error>"
    end

    test "CalendarSyncError.render/2 handles XML-hostile binary error without crashing" do
      meeting = insert(:meeting)
      html = CalendarSyncError.render(meeting, "Response: <foo/> & </bar> unclosed")

      assert html =~ "</html>"
      assert html =~ "Error Details"
      refute html =~ "<foo/>"
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input and the expected structural content is always present.

    test "CalendarSyncError.render_text returns a valid binary with malicious error reason" do
      meeting = insert(:meeting)
      text = CalendarSyncError.render_text(meeting, "<script>alert('xss')</script>")

      assert text =~ "Calendar Sync Error"
      assert text =~ "ACTION REQUIRED"
      assert text =~ "<script>alert('xss')</script>"
    end

    test "CalendarSyncError.render_text returns a valid binary with malicious location" do
      meeting = insert(:meeting, location: "Room A\nX-Injected: evil-header")
      text = CalendarSyncError.render_text(meeting, :network_error)

      assert text =~ "Calendar Sync Error"
      assert text =~ "Location: Room A"
    end
  end
end
