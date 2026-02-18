defmodule Tymeslot.Emails.Shared.MeetingComponentsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.MeetingComponents

  describe "meeting_details_table/1" do
    test "sanitizes user-provided location" do
      details = %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        location: "<script>alert('xss')</script>Conference Room"
      }

      html = MeetingComponents.meeting_details_table(details)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "Conference Room"
    end

    test "sanitizes meeting type" do
      details = %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        meeting_type: "<img src=x onerror=alert(1)>Demo"
      }

      html = MeetingComponents.meeting_details_table(details)

      refute html =~ "<img src=x"
      assert html =~ "Demo"
    end

    test "handles nil location gracefully" do
      details = %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        location: nil
      }

      html = MeetingComponents.meeting_details_table(details)

      assert html =~ "TBD"
    end

    test "includes all meeting details" do
      details = %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        location: "Virtual Meeting",
        meeting_type: "Discovery Call"
      }

      html = MeetingComponents.meeting_details_table(details)

      assert html =~ "1 hour"
      assert html =~ "Virtual Meeting"
      assert html =~ "Discovery Call"
    end
  end

  describe "video_meeting_section/2" do
    test "sanitizes meeting URL" do
      malicious_url = "https://meet.example.com/<script>alert('xss')</script>"
      html = MeetingComponents.video_meeting_section(malicious_url)

      # URL should be sanitized in href attribute
      refute html =~ "<script>"
    end

    test "includes meeting URL in button" do
      url = "https://meet.example.com/room123"
      html = MeetingComponents.video_meeting_section(url)

      assert html =~ url
      assert html =~ "Join Meeting"
    end

    test "supports different styles" do
      url = "https://meet.example.com/room123"

      for style <- [:reminder, :confirmation, :subtle, :default] do
        html = MeetingComponents.video_meeting_section(url, style: style)
        assert is_binary(html)
        assert html =~ url
      end
    end

    test "allows custom title and button text" do
      url = "https://meet.example.com/room123"

      html =
        MeetingComponents.video_meeting_section(url,
          title: "Custom Title",
          button_text: "Custom Button"
        )

      assert html =~ "Custom Title"
      assert html =~ "Custom Button"
    end
  end

  describe "time_alert_badge/2" do
    test "sanitizes time text" do
      html = MeetingComponents.time_alert_badge("<script>alert('xss')</script>30 minutes")

      refute html =~ "<script>"
      assert html =~ "30 minutes"
    end

    test "supports custom icon" do
      html = MeetingComponents.time_alert_badge("Starting soon", icon: "⏰")

      assert html =~ "⏰"
      assert html =~ "Starting soon"
    end

    test "supports different colors" do
      for color <- [:blue, :green, :red] do
        html = MeetingComponents.time_alert_badge("Time text", color: color)
        assert is_binary(html)
        assert html =~ "Time text"
      end
    end
  end
end
