defmodule Tymeslot.Integrations.Calendar.IcsGeneratorTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

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

  describe "locale-aware ICS content" do
    test "translates 'Video Call' location into German" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details, "de")

      assert ics_content =~ "LOCATION:Videoanruf"
      refute ics_content =~ "LOCATION:Video Call"
    end

    test "translates video meeting label in description into German" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details, "de")

      assert ics_content =~ "Video-Meeting:"
      refute ics_content =~ "Video meeting:"
    end

    test "translates attendee message label into German" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        attendee_name: "Klaus",
        attendee_message: "Freue mich auf unser Gespräch"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details, "de")

      assert ics_content =~ "Nachricht von Klaus:"
      refute ics_content =~ "Message from Klaus:"
    end

    test "English locale produces English strings" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        meeting_url: "https://meet.example.com/room123"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details, "en")

      assert ics_content =~ "LOCATION:Video Call"
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

  describe "generate_ics_attachment/3" do
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
      assert attachment.content_type =~ "method=PUBLISH"
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

      attachment =
        IcsGenerator.generate_ics_attachment(meeting_details, "en", "custom-invite.ics")

      assert attachment.filename == "custom-invite.ics"
    end

    test "advertises METHOD:PUBLISH (not REQUEST) to suppress recipient-side iMIP auto-import" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      attachment = IcsGenerator.generate_ics_attachment(meeting_details)

      assert attachment.content_type == "text/calendar; charset=utf-8; method=PUBLISH"
      assert attachment.data =~ "METHOD:PUBLISH"
      refute attachment.data =~ "METHOD:REQUEST"
    end
  end

  describe "generate_ics_cancel_attachment/4" do
    test "emits METHOD:PUBLISH + STATUS:CANCELLED with the given SEQUENCE" do
      meeting_details = %{
        title: "Cancelled Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "cancel-me-123",
        organizer_email: "organizer@example.com",
        attendee_email: "jane@example.com"
      }

      attachment = IcsGenerator.generate_ics_cancel_attachment(meeting_details, 3)

      assert %Swoosh.Attachment{} = attachment
      assert attachment.content_type == "text/calendar; charset=utf-8; method=PUBLISH"
      assert attachment.data =~ "METHOD:PUBLISH"
      refute attachment.data =~ "METHOD:CANCEL"
      assert attachment.data =~ "SEQUENCE:3"
      assert attachment.data =~ "STATUS:CANCELLED"
    end
  end

  describe "generate_ics_update_attachment/4" do
    test "advertises METHOD:PUBLISH (not REQUEST) in content-type and data" do
      meeting_details = %{
        title: "Updated Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "update-me-123",
        organizer_email: "organizer@example.com"
      }

      attachment = IcsGenerator.generate_ics_update_attachment(meeting_details, 1)

      assert attachment.content_type =~ "method=PUBLISH"
      assert attachment.data =~ "METHOD:PUBLISH"
      refute attachment.data =~ "METHOD:REQUEST"
    end

    test "includes SEQUENCE line reflecting the given sequence number" do
      meeting_details = %{
        title: "Updated Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "update-me-123",
        organizer_email: "organizer@example.com"
      }

      attachment = IcsGenerator.generate_ics_update_attachment(meeting_details, 2)

      assert attachment.data =~ "SEQUENCE:2"
    end

    test "retains STATUS:CONFIRMED on an update" do
      meeting_details = %{
        title: "Updated Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "update-me-123",
        organizer_email: "organizer@example.com"
      }

      attachment = IcsGenerator.generate_ics_update_attachment(meeting_details, 1)

      assert attachment.data =~ "STATUS:CONFIRMED"
      refute attachment.data =~ "STATUS:CANCELLED"
    end

    test "ORGANIZER and ATTENDEE lines carry SCHEDULE-AGENT=CLIENT" do
      meeting_details = %{
        title: "Updated Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "update-me-123",
        organizer_email: "organizer@example.com",
        organizer_name: "Alice",
        attendee_email: "bob@example.com",
        attendee_name: "Bob"
      }

      attachment = IcsGenerator.generate_ics_update_attachment(meeting_details, 1)

      assert attachment.data =~ ~r/^ORGANIZER;SCHEDULE-AGENT=CLIENT[;:]/m
      assert attachment.data =~ ~r/^ATTENDEE;SCHEDULE-AGENT=CLIENT[;:]/m
    end
  end

  describe "CN parameter sanitisation" do
    test "prevents CRLF injection from attendee name from creating new property lines" do
      meeting_details = %{
        title: "Injection Test",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "inject-123",
        organizer_email: "org@example.com",
        attendee_email: "victim@example.com",
        attendee_name: "Jane\r\nX-INJECTED:malicious"
      }

      attachment = IcsGenerator.generate_ics_attachment(meeting_details)

      # The CRLF must not produce a bare new property line in the output.
      refute attachment.data =~ ~r/^X-INJECTED:malicious/m
      refute attachment.data =~ "\r\nX-INJECTED"
      refute attachment.data =~ "\nX-INJECTED"
    end

    test "prevents CRLF injection from organizer name from creating new property lines" do
      meeting_details = %{
        title: "Injection Test",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "inject-org-123",
        organizer_email: "org@example.com",
        organizer_name: "Alice\r\nX-INJECTED:malicious"
      }

      attachment = IcsGenerator.generate_ics_attachment(meeting_details)

      refute attachment.data =~ ~r/^X-INJECTED:malicious/m
      refute attachment.data =~ "\r\nX-INJECTED"
      refute attachment.data =~ "\nX-INJECTED"
    end
  end

  # RFC 6638 §7.1: tagging ORGANIZER/ATTENDEE with SCHEDULE-AGENT=CLIENT
  # signals to scheduling-aware CalDAV servers and iMIP-aware mail servers
  # that the client handles all scheduling — they must not fire their own
  # iTIP pipeline. Without this, Zimbra/Nextcloud/iCloud auto-generate a
  # second set of notifications (see issue #41).
  describe "SCHEDULE-AGENT=CLIENT suppression of recipient-side iTIP" do
    test "ORGANIZER line carries SCHEDULE-AGENT=CLIENT" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        organizer_name: "John Smith"
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      assert ics =~ ~r/^ORGANIZER;SCHEDULE-AGENT=CLIENT[;:]/m
    end

    test "ATTENDEE line carries SCHEDULE-AGENT=CLIENT when present" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com",
        attendee_email: "jane@example.com",
        attendee_name: "Jane Doe"
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      assert ics =~ ~r/^ATTENDEE;SCHEDULE-AGENT=CLIENT[;:]/m
    end

    test "ORGANIZER without a name still carries SCHEDULE-AGENT=CLIENT" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "meeting-123",
        organizer_email: "john@example.com"
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      assert ics =~ "ORGANIZER;SCHEDULE-AGENT=CLIENT:mailto:john@example.com"
    end
  end
end
