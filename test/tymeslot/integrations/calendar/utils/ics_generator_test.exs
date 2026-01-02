defmodule Tymeslot.Integrations.Calendar.IcsGeneratorTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Integrations.Calendar.IcsGenerator

  describe "generate_ics/1" do
    test "generates valid ICS content with required fields" do
      meeting_details = %{
        title: "Test Meeting",
        description: "This is a test meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "test-meeting-123",
        organizer_email: "organizer@example.com",
        organizer_name: "John Doe"
      }

      # Ensure we use the domain from configuration
      domain = Application.get_env(:tymeslot, :email)[:domain]
      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert is_binary(ics_content)
      assert ics_content =~ "BEGIN:VCALENDAR"
      assert ics_content =~ "END:VCALENDAR"
      assert ics_content =~ "BEGIN:VEVENT"
      assert ics_content =~ "END:VEVENT"
      assert ics_content =~ "SUMMARY:Test Meeting"
      assert ics_content =~ "UID:test-meeting-123@#{domain}"
    end

    test "includes organizer information" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        organizer_name: "John Smith"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "ORGANIZER"
      assert ics_content =~ "john@example.com"
      assert ics_content =~ "John Smith"
    end

    test "includes attendee information when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        attendee_email: "jane@example.com",
        attendee_name: "Jane Doe"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "ATTENDEE"
      assert ics_content =~ "jane@example.com"
      assert ics_content =~ "Jane Doe"
    end

    test "handles missing optional attendee information" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      # Should still generate valid ICS without attendee
      assert is_binary(ics_content)
      assert ics_content =~ "BEGIN:VCALENDAR"
    end

    test "includes location when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        location: "Conference Room A"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "LOCATION"
      assert ics_content =~ "Conference Room A"
    end

    test "uses 'Video Call' as location when meeting_url is provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "LOCATION:Video Call"
    end

    test "includes video URL in description when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "Video meeting: https://meet.example.com/room123"
    end

    test "includes attendee message in description when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        attendee_name: "Jane",
        attendee_message: "Looking forward to discussing the project"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "Message from Jane"
      assert ics_content =~ "Looking forward to discussing the project"
    end
  end

  describe "escaping and edge cases" do
    test "escapes special iCalendar characters in description" do
      meeting_details = %{
        title: "Special Characters",
        description: "Backslash: \\, Semicolon: ;, Comma: ,",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "special-123",
        organizer_email: "org@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      # If using Magical, it should escape. If using fallback, we explicitly escape.
      assert ics_content =~ "Backslash: \\\\"
      assert ics_content =~ "Semicolon: \\;"
      assert ics_content =~ "Comma: \\,"
    end

    test "escapes newlines in description" do
      meeting_details = %{
        title: "Multi-line",
        description: "Line 1\nLine 2",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "multiline-123",
        organizer_email: "org@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "Line 1\\nLine 2"
    end

    test "handles emojis and non-ASCII characters" do
      meeting_details = %{
        title: "Emoji Test 🚀",
        description: "Thinking... 🤔 & Fun!",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "emoji-123",
        organizer_email: "org@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "Emoji Test 🚀"
      assert ics_content =~ "Thinking... 🤔"
    end

    test "handles extremely long strings gracefully" do
      long_description = String.duplicate("This is a very long description. ", 100)
      meeting_details = %{
        title: "Long String Test",
        description: long_description,
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "long-123",
        organizer_email: "org@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert is_binary(ics_content)
      assert String.length(ics_content) > 3000
    end
  end

  describe "generate_ics_attachment/2" do
    test "creates valid Swoosh attachment with ICS content" do
      meeting_details = %{
        title: "Test Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      attachment = IcsGenerator.generate_ics_attachment(meeting_details)

      assert %Swoosh.Attachment{} = attachment
      assert attachment.filename == "meeting.ics"
      assert attachment.content_type =~ "text/calendar"
      assert attachment.content_type =~ "method=REQUEST"
      assert is_binary(attachment.data)
      assert attachment.data =~ "BEGIN:VCALENDAR"
    end

    test "uses custom filename when provided" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      attachment = IcsGenerator.generate_ics_attachment(meeting_details, "custom-invite.ics")

      assert attachment.filename == "custom-invite.ics"
    end

    test "sets correct content type with charset and method" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      attachment = IcsGenerator.generate_ics_attachment(meeting_details)

      assert attachment.content_type == "text/calendar; charset=utf-8; method=REQUEST"
    end
  end
end
