defmodule Tymeslot.Integrations.Calendar.ICalBuilderTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalBuilder

  describe "build_event/1" do
    test "builds complete iCalendar event with required fields" do
      event_data = %{
        summary: "Team Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "BEGIN:VCALENDAR")
      assert String.contains?(ical, "VERSION:2.0")
      assert String.contains?(ical, "BEGIN:VEVENT")
      assert String.contains?(ical, "SUMMARY:Team Meeting")
      assert String.contains?(ical, "END:VEVENT")
      assert String.contains?(ical, "END:VCALENDAR")
    end

    test "includes DTSTART and DTEND in correct format" do
      event_data = %{
        summary: "Test Event",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "DTSTART:20240115T100000Z")
      assert String.contains?(ical, "DTEND:20240115T110000Z")
    end

    test "generates unique UID when not provided" do
      event_data = %{
        summary: "Event Without UID",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "UID:")
      assert String.contains?(ical, "@tymeslot.com")
    end

    test "uses provided UID when given" do
      event_data = %{
        uid: "custom-event-123",
        summary: "Event With Custom UID",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "UID:custom-event-123")
    end

    test "includes DTSTAMP with current time" do
      event_data = %{
        summary: "Test",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "DTSTAMP:")
    end

    test "includes optional description" do
      event_data = %{
        summary: "Meeting",
        description: "This is a detailed description",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "DESCRIPTION:This is a detailed description")
    end

    test "includes optional location" do
      event_data = %{
        summary: "Meeting",
        location: "Conference Room A",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "LOCATION:Conference Room A")
    end

    test "includes organizer when provided" do
      event_data = %{
        summary: "Meeting",
        organizer: "organizer@example.com",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "ORGANIZER:mailto:organizer@example.com")
    end

    test "includes attendees when provided" do
      event_data = %{
        summary: "Meeting",
        attendees: ["john@example.com", "jane@example.com"],
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "ATTENDEE")
      assert String.contains?(ical, "john@example.com")
      assert String.contains?(ical, "jane@example.com")
    end

    test "includes status when provided" do
      event_data = %{
        summary: "Meeting",
        status: "CONFIRMED",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "STATUS:CONFIRMED")
    end

    test "includes URL when provided" do
      event_data = %{
        summary: "Meeting",
        url: "https://meet.example.com/room123",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "URL:https://meet.example.com/room123")
    end

    test "handles all-day events" do
      event_data = %{
        summary: "All Day Event",
        start_time: ~U[2024-01-15 00:00:00Z],
        end_time: ~U[2024-01-16 00:00:00Z],
        all_day: true
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "DTSTART;VALUE=DATE:")
      assert String.contains?(ical, "DTEND;VALUE=DATE:")
    end
  end

  describe "build_simple_event/2" do
    test "builds minimal iCalendar event" do
      uid = "simple-event-123"

      event_data = %{
        summary: "Simple Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event(uid, event_data)

      assert String.contains?(ical, "BEGIN:VCALENDAR")
      assert String.contains?(ical, "UID:simple-event-123")
      assert String.contains?(ical, "SUMMARY:Simple Meeting")
      assert String.contains?(ical, "END:VCALENDAR")
    end

    test "includes empty description and location when not provided" do
      uid = "test-uid"

      event_data = %{
        summary: "Test",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event(uid, event_data)

      assert String.contains?(ical, "DESCRIPTION:")
      assert String.contains?(ical, "LOCATION:")
    end

    test "includes provided description and location" do
      uid = "test-uid"

      event_data = %{
        summary: "Test",
        description: "Test description",
        location: "Test location",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event(uid, event_data)

      assert String.contains?(ical, "DESCRIPTION:Test description")
      assert String.contains?(ical, "LOCATION:Test location")
    end
  end

  describe "generate_uid/0" do
    test "generates unique identifier" do
      uid1 = ICalBuilder.generate_uid()
      uid2 = ICalBuilder.generate_uid()

      assert uid1 != uid2
      assert String.contains?(uid1, "@tymeslot.com")
      assert String.contains?(uid2, "@tymeslot.com")
    end

    test "generates UID in correct format" do
      uid = ICalBuilder.generate_uid()

      assert String.ends_with?(uid, "@tymeslot.com")
      assert String.length(uid) > 20
    end
  end

  describe "format_datetime/1" do
    test "formats DateTime in iCalendar format" do
      datetime = ~U[2024-01-15 10:30:45.123456Z]

      formatted = ICalBuilder.format_datetime(datetime)

      assert formatted == "20240115T103045Z"
    end

    test "removes fractional seconds" do
      datetime = ~U[2024-12-31 23:59:59.999999Z]

      formatted = ICalBuilder.format_datetime(datetime)

      assert formatted == "20241231T235959Z"
      refute String.contains?(formatted, ".")
    end

    test "formats midnight correctly" do
      datetime = ~U[2024-06-15 00:00:00Z]

      formatted = ICalBuilder.format_datetime(datetime)

      assert formatted == "20240615T000000Z"
    end
  end

  describe "format_date/1" do
    test "formats Date in iCalendar format" do
      date = ~D[2024-01-15]

      formatted = ICalBuilder.format_date(date)

      assert formatted == "20240115"
    end

    test "formats various dates correctly" do
      assert ICalBuilder.format_date(~D[2024-12-31]) == "20241231"
      assert ICalBuilder.format_date(~D[2024-01-01]) == "20240101"
      assert ICalBuilder.format_date(~D[2024-06-15]) == "20240615"
    end
  end

  describe "escape_text/1" do
    test "returns empty string for nil" do
      assert ICalBuilder.escape_text(nil) == ""
    end

    test "escapes backslashes" do
      assert ICalBuilder.escape_text("C:\\path\\to\\file") == "C:\\\\path\\\\to\\\\file"
    end

    test "escapes commas" do
      assert ICalBuilder.escape_text("one, two, three") == "one\\, two\\, three"
    end

    test "escapes semicolons" do
      assert ICalBuilder.escape_text("key;value;pair") == "key\\;value\\;pair"
    end

    test "escapes newlines" do
      assert ICalBuilder.escape_text("line1\nline2") == "line1\\nline2"
    end

    test "removes carriage returns" do
      assert ICalBuilder.escape_text("text\r\nmore") == "text\\nmore"
    end

    test "handles multiple special characters" do
      text = "Path: C:\\test; value,\nNext line"
      escaped = ICalBuilder.escape_text(text)

      assert String.contains?(escaped, "\\\\")
      assert String.contains?(escaped, "\\;")
      assert String.contains?(escaped, "\\,")
      assert String.contains?(escaped, "\\n")
    end

    test "preserves regular text" do
      assert ICalBuilder.escape_text("Regular text 123") == "Regular text 123"
    end
  end

  describe "build_event/1 — Date{} all-day path" do
    test "emits VALUE=DATE for start_time as a Date struct" do
      event_data = %{
        summary: "All Day via Date",
        start_time: ~D[2026-04-18],
        end_time: ~D[2026-04-19]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "DTSTART;VALUE=DATE:20260418")
      assert String.contains?(ical, "DTEND;VALUE=DATE:20260419")
    end

    test "does not include a Z suffix in the date-only value" do
      event_data = %{
        summary: "Date Only Event",
        start_time: ~D[2026-04-18],
        end_time: ~D[2026-04-19]
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "DTSTART;VALUE=DATE:20260418T")
      refute String.contains?(ical, "DTEND;VALUE=DATE:20260419T")
    end
  end

  describe "build_event/1 — NaiveDateTime floating-time path" do
    test "emits DTSTART and DTEND without Z suffix for NaiveDateTime" do
      event_data = %{
        summary: "Floating Time Event",
        start_time: ~N[2026-04-18 10:00:00],
        end_time: ~N[2026-04-18 11:00:00]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "DTSTART:20260418T100000")
      assert String.contains?(ical, "DTEND:20260418T110000")
    end

    test "does not include Z suffix for NaiveDateTime values" do
      event_data = %{
        summary: "No UTC marker",
        start_time: ~N[2026-04-18 10:00:00],
        end_time: ~N[2026-04-18 11:00:00]
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "DTSTART:20260418T100000Z")
      refute String.contains?(ical, "DTEND:20260418T110000Z")
    end

    test "does not include TZID parameter for NaiveDateTime values" do
      event_data = %{
        summary: "Floating",
        start_time: ~N[2026-04-18 10:00:00],
        end_time: ~N[2026-04-18 11:00:00]
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "DTSTART;TZID=")
      refute String.contains?(ical, "DTEND;TZID=")
    end
  end

  describe "build_event/1 — atom status and transparency" do
    test "upcases atom :tentative to STATUS:TENTATIVE" do
      event_data = %{
        summary: "Maybe",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        status: :tentative
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "STATUS:TENTATIVE")
    end

    test "upcases atom :confirmed to STATUS:CONFIRMED" do
      event_data = %{
        summary: "Confirmed",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        status: :confirmed
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "STATUS:CONFIRMED")
    end

    test "silently skips an invalid atom status" do
      event_data = %{
        summary: "Bad Status",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        status: :unknown_status
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "STATUS:")
    end

    test "upcases atom :opaque to TRANSP:OPAQUE" do
      event_data = %{
        summary: "Busy",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        transparency: :opaque
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "TRANSP:OPAQUE")
    end

    test "upcases atom :transparent to TRANSP:TRANSPARENT" do
      event_data = %{
        summary: "Free",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        transparency: :transparent
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "TRANSP:TRANSPARENT")
    end

    test "silently skips an invalid atom transparency" do
      event_data = %{
        summary: "Bad Transparency",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        transparency: :unknown_transparency
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "TRANSP:")
    end
  end

  describe "build_event/1 — visibility producing CLASS property" do
    test "emits CLASS:PRIVATE for :private visibility" do
      event_data = %{
        summary: "Private Event",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :private
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "CLASS:PRIVATE")
    end

    test "emits CLASS:PUBLIC for :public visibility" do
      event_data = %{
        summary: "Public Event",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :public
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "CLASS:PUBLIC")
    end

    test "emits CLASS:CONFIDENTIAL for :confidential visibility" do
      event_data = %{
        summary: "Confidential Event",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :confidential
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "CLASS:CONFIDENTIAL")
    end

    test "accepts string visibility values" do
      event_data = %{
        summary: "String Visibility",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: "private"
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "CLASS:PRIVATE")
    end

    test "silently skips an invalid visibility value" do
      event_data = %{
        summary: "Bad Visibility",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :internal
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "CLASS:")
    end
  end

  describe "build_rrule/1" do
    test "returns nil for nil input" do
      assert ICalBuilder.build_rrule(nil) == nil
    end

    test "builds simple DAILY recurrence" do
      recurrence = %{frequency: "DAILY"}

      rrule = ICalBuilder.build_rrule(recurrence)

      assert rrule == "RRULE:FREQ=DAILY"
    end

    test "builds WEEKLY recurrence with days" do
      recurrence = %{
        frequency: "WEEKLY",
        by_day: ["MO", "WE", "FR"]
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert rrule == "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"
    end

    test "includes interval when greater than 1" do
      recurrence = %{
        frequency: "WEEKLY",
        interval: 2
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "INTERVAL=2")
    end

    test "includes count when provided" do
      recurrence = %{
        frequency: "DAILY",
        count: 10
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "COUNT=10")
    end

    test "includes until date when provided" do
      until_date = ~U[2024-12-31 23:59:59Z]

      recurrence = %{
        frequency: "WEEKLY",
        until: until_date
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "UNTIL=")
      assert String.contains?(rrule, "20241231T235959Z")
    end

    test "includes by_month when provided" do
      recurrence = %{
        frequency: "YEARLY",
        by_month: [1, 6, 12]
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "BYMONTH=1,6,12")
    end

    test "builds complex recurrence rule" do
      recurrence = %{
        frequency: "MONTHLY",
        interval: 2,
        count: 12,
        by_day: ["MO"]
      }

      rrule = ICalBuilder.build_rrule(recurrence)

      assert String.contains?(rrule, "FREQ=MONTHLY")
      assert String.contains?(rrule, "INTERVAL=2")
      assert String.contains?(rrule, "COUNT=12")
      assert String.contains?(rrule, "BYDAY=MO")
    end
  end
end
