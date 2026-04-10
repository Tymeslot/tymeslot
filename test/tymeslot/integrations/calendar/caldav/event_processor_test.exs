defmodule Tymeslot.Integrations.Calendar.CalDAV.EventProcessorTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalendarEvent

  describe "clean_etag/1" do
    test "strips surrounding double-quotes" do
      assert EventProcessor.clean_etag("\"abc123\"") == "abc123"
    end

    test "strips surrounding whitespace" do
      assert EventProcessor.clean_etag("  abc123  ") == "abc123"
    end

    test "strips whitespace then quotes" do
      assert EventProcessor.clean_etag("  \"abc123\"  ") == "abc123"
    end

    test "leaves etags without quotes unchanged" do
      assert EventProcessor.clean_etag("abc123") == "abc123"
    end

    test "returns nil for non-binary input" do
      assert EventProcessor.clean_etag(nil) == nil
      assert EventProcessor.clean_etag(42) == nil
    end
  end

  describe "parse_ical_from_string/1" do
    @valid_ical """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//Test//EN
    BEGIN:VEVENT
    UID:test-uid-001@example.com
    DTSTART:20300315T100000Z
    DTEND:20300315T110000Z
    SUMMARY:Team Meeting
    END:VEVENT
    END:VCALENDAR
    """

    test "parses a valid iCalendar string and returns the first event" do
      assert {:ok, event} = EventProcessor.parse_ical_from_string(@valid_ical)
      assert Map.get(event, :uid) == "test-uid-001@example.com"
      assert Map.get(event, :summary) == "Team Meeting"
    end

    test "returns {:error, :empty_data} for nil" do
      assert EventProcessor.parse_ical_from_string(nil) == {:error, :empty_data}
    end

    test "returns {:error, :empty_data} for empty string" do
      assert EventProcessor.parse_ical_from_string("") == {:error, :empty_data}
    end

    test "returns {:error, :empty_data} for non-binary input" do
      assert EventProcessor.parse_ical_from_string(42) == {:error, :empty_data}
    end

    test "parses attendees from an iCalendar string" do
      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:with-attendees@example.com
      DTSTART:20300315T100000Z
      DTEND:20300315T110000Z
      SUMMARY:Group Meeting
      ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com
      ATTENDEE;CN=Bob;PARTSTAT=TENTATIVE:mailto:bob@example.com
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = EventProcessor.parse_ical_from_string(ical)
      assert [alice, bob] = Map.get(event, :attendees)
      assert alice["email"] == "alice@example.com"
      assert alice["name"] == "Alice"
      assert alice["status"] == "accepted"
      assert bob["email"] == "bob@example.com"
      assert bob["status"] == "tentative"
    end

    test "parses recurrence rule from an iCalendar string" do
      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:recurring@example.com
      DTSTART:20300315T100000Z
      DTEND:20300315T110000Z
      SUMMARY:Weekly Sync
      RRULE:FREQ=WEEKLY;INTERVAL=1
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = EventProcessor.parse_ical_from_string(ical)
      assert Map.get(event, :recurrence_rule) == "FREQ=WEEKLY;INTERVAL=1"
    end

    test "maps TRANSP:TRANSPARENT to transparency field" do
      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:free-event@example.com
      DTSTART:20300315T100000Z
      DTEND:20300315T110000Z
      SUMMARY:Out of Office
      TRANSP:TRANSPARENT
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = EventProcessor.parse_ical_from_string(ical)
      assert Map.get(event, :transparency) == "transparent"
    end
  end

  # ---------------------------------------------------------------------------
  # normalise_events/2
  # ---------------------------------------------------------------------------

  describe "normalise_events/2" do
    @context %{
      calendar_integration_id: 42,
      provider_calendar_id: "default",
      synced_at: ~U[2026-04-08 12:00:00Z]
    }

    test "normalises a standard timed VEVENT into a CalendarEvent" do
      raw = %{
        uid: "timed-001@example.com",
        summary: "Team Standup",
        description: "Daily sync",
        location: "Room 3",
        dtstart: ~U[2030-06-15 09:00:00Z],
        dtend: ~U[2030-06-15 09:30:00Z],
        transp: "OPAQUE",
        status: "CONFIRMED",
        etag: "\"abc123\""
      }

      assert {:ok, [%CalendarEvent{} = event]} = EventProcessor.normalise_events([raw], @context)

      assert event.uid == "timed-001@example.com"
      assert event.provider == :caldav
      assert event.calendar_integration_id == 42
      assert event.provider_calendar_id == "default"
      assert event.summary == "Team Standup"
      assert event.description == "Daily sync"
      assert event.location == "Room 3"
      assert event.all_day == false
      assert event.start_at == ~U[2030-06-15 09:00:00Z]
      assert event.end_at == ~U[2030-06-15 09:30:00Z]
      assert event.transparency == :opaque
      assert event.status == :confirmed
      assert event.etag == "\"abc123\""
      assert event.synced_at == ~U[2026-04-08 12:00:00Z]
      assert event.provider_metadata == raw
    end

    test "normalises an all-day event with Date dtstart/dtend" do
      raw = %{
        uid: "allday-001@example.com",
        summary: "Holiday",
        dtstart: ~D[2030-12-25],
        dtend: ~D[2030-12-26]
      }

      assert {:ok, [%CalendarEvent{} = event]} = EventProcessor.normalise_events([raw], @context)

      assert event.all_day == true
      assert event.start_date == ~D[2030-12-25]
      assert event.end_date == ~D[2030-12-26]
      assert event.start_at == nil
      assert event.end_at == nil
    end

    test "detects Radicale all-day pattern (midnight UTC DateTimes) and converts to Date" do
      raw = %{
        uid: "radicale-allday@example.com",
        summary: "Blocked Day",
        dtstart: ~U[2030-03-15 00:00:00Z],
        dtend: ~U[2030-03-16 00:00:00Z]
      }

      assert {:ok, [%CalendarEvent{} = event]} = EventProcessor.normalise_events([raw], @context)

      assert event.all_day == true
      assert event.start_date == ~D[2030-03-15]
      assert event.end_date == ~D[2030-03-16]
      assert event.start_at == nil
      assert event.end_at == nil
    end

    test "all-day event with only DTSTART and no DTEND defaults end_date to start_date + 1" do
      # RFC 5545 §3.8.2.2 — DTEND is optional for DATE-valued events; the
      # default duration is P1D (one calendar day).
      raw = %{
        uid: "no-dtend@example.com",
        summary: "Single Day Holiday",
        dtstart: ~D[2030-07-04]
      }

      assert {:ok, [%CalendarEvent{} = event]} = EventProcessor.normalise_events([raw], @context)

      assert event.all_day == true
      assert event.start_date == ~D[2030-07-04]
      assert event.end_date == ~D[2030-07-05]
      assert event.start_at == nil
      assert event.end_at == nil
    end

    test "TRANSP:TRANSPARENT maps to transparency: :transparent" do
      raw = %{
        uid: "free-001@example.com",
        summary: "Out of Office",
        dtstart: ~U[2030-06-15 09:00:00Z],
        dtend: ~U[2030-06-15 17:00:00Z],
        transp: "TRANSPARENT"
      }

      assert {:ok, [%CalendarEvent{} = event]} = EventProcessor.normalise_events([raw], @context)
      assert event.transparency == :transparent
    end

    test "CLASS maps to visibility" do
      raw = %{
        uid: "private-001@example.com",
        summary: "Confidential",
        dtstart: ~U[2030-06-15 09:00:00Z],
        dtend: ~U[2030-06-15 10:00:00Z],
        class: "PRIVATE"
      }

      assert {:ok, [%CalendarEvent{} = event]} = EventProcessor.normalise_events([raw], @context)
      assert event.visibility == :private
    end

    test "expands recurring event with RRULE into multiple CalendarEvent structs" do
      raw = %{
        uid: "recurring-001@example.com",
        summary: "Weekly Sync",
        dtstart: ~U[2026-04-08 10:00:00Z],
        dtend: ~U[2026-04-08 11:00:00Z],
        rrule: "FREQ=WEEKLY;COUNT=3"
      }

      assert {:ok, events} = EventProcessor.normalise_events([raw], @context)

      assert length(events) == 3

      [first | rest] = events
      assert first.uid == "recurring-001@example.com_20260408T100000Z"
      assert first.summary == "Weekly Sync"
      assert first.recurrence_rule == "FREQ=WEEKLY;COUNT=3"
      assert first.all_day == false

      # Subsequent occurrences have different UIDs
      uids = Enum.uniq(Enum.map(events, & &1.uid))
      assert length(uids) == 3

      # Verify the occurrences are 1 week apart
      starts = Enum.sort(Enum.map(events, & &1.start_at), DateTime)

      Enum.each(Enum.chunk_every(starts, 2, 1, :discard), fn [a, b] ->
        assert DateTime.diff(b, a, :day) == 7
      end)

      # All share the same recurrence_rule
      assert Enum.all?(rest, &(&1.recurrence_rule == "FREQ=WEEKLY;COUNT=3"))
    end

    test "EXDATE handling excludes the matching occurrence" do
      # Weekly event with 3 occurrences, but the second is excluded
      excluded = ~U[2026-04-15 10:00:00Z]

      raw = %{
        uid: "exdate-001@example.com",
        summary: "Weekly with exclusion",
        dtstart: ~U[2026-04-08 10:00:00Z],
        dtend: ~U[2026-04-08 11:00:00Z],
        rrule: "FREQ=WEEKLY;COUNT=3",
        exdate: [excluded]
      }

      assert {:ok, events} = EventProcessor.normalise_events([raw], @context)

      # Should have 2, not 3 (the second week is excluded)
      assert length(events) == 2

      starts = Enum.sort(Enum.map(events, & &1.start_at), DateTime)
      refute excluded in starts
    end

    test "skips event with invalid data and sends admin alert" do
      valid_raw = %{
        uid: "good-001@example.com",
        summary: "Good Event",
        dtstart: ~U[2030-06-15 09:00:00Z],
        dtend: ~U[2030-06-15 10:00:00Z]
      }

      # Missing UID — will fail CalendarEvent.new/1 validation
      invalid_raw = %{
        uid: nil,
        summary: "Bad Event",
        dtstart: ~U[2030-06-15 09:00:00Z],
        dtend: ~U[2030-06-15 10:00:00Z]
      }

      log =
        capture_log(fn ->
          assert {:ok, events} =
                   EventProcessor.normalise_events([valid_raw, invalid_raw], @context)

          # Only the valid event should be in the result
          assert length(events) == 1
          assert hd(events).uid == "good-001@example.com"
        end)

      assert log =~ "Skipping invalid CalDAV calendar event"
    end

    test "skips event with no UID" do
      raw = %{
        summary: "No UID Event",
        dtstart: ~U[2030-06-15 09:00:00Z],
        dtend: ~U[2030-06-15 10:00:00Z]
      }

      log =
        capture_log(fn ->
          assert {:ok, []} = EventProcessor.normalise_events([raw], @context)
        end)

      assert log =~ "Skipping invalid CalDAV calendar event"
    end

    test "handles empty event list" do
      assert {:ok, []} = EventProcessor.normalise_events([], @context)
    end

    test "maps attendees from parsed iCal format" do
      raw = %{
        uid: "attendees-001@example.com",
        summary: "Group Meeting",
        dtstart: ~U[2030-06-15 09:00:00Z],
        dtend: ~U[2030-06-15 10:00:00Z],
        attendee: [
          %{"email" => "alice@example.com", "name" => "Alice", "status" => "accepted"},
          %{"email" => "bob@example.com", "name" => "Bob", "status" => "tentative"}
        ]
      }

      assert {:ok, [event]} = EventProcessor.normalise_events([raw], @context)
      assert length(event.attendees) == 2

      [alice, bob] = event.attendees
      assert alice.email == "alice@example.com"
      assert alice.display_name == "Alice"
      assert alice.response_status == :accepted
      assert bob.response_status == :tentative
    end

    test "maps organiser from parsed iCal format" do
      raw = %{
        uid: "organiser-001@example.com",
        summary: "Organised Meeting",
        dtstart: ~U[2030-06-15 09:00:00Z],
        dtend: ~U[2030-06-15 10:00:00Z],
        organizer: %{"email" => "boss@example.com", "CN" => "The Boss"}
      }

      assert {:ok, [event]} = EventProcessor.normalise_events([raw], @context)
      assert event.organiser.email == "boss@example.com"
      assert event.organiser.display_name == "The Boss"
    end

    test "maps STATUS field correctly" do
      for {ical_status, expected} <- [
            {"CONFIRMED", :confirmed},
            {"TENTATIVE", :tentative},
            {"CANCELLED", :cancelled}
          ] do
        raw = %{
          uid: "status-#{ical_status}@example.com",
          summary: "Status test",
          dtstart: ~U[2030-06-15 09:00:00Z],
          dtend: ~U[2030-06-15 10:00:00Z],
          status: ical_status
        }

        assert {:ok, [event]} = EventProcessor.normalise_events([raw], @context)
        assert event.status == expected
      end
    end
  end
end
