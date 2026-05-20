defmodule Tymeslot.Integrations.Calendar.IcsGeneratorSecurityTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.IcsGenerator

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
