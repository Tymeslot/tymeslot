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

      # The stamp is when the event was written, not when it starts — a hard
      # coded epoch, an empty value, or the event's own start time would all
      # satisfy "contains DTSTAMP:".
      assert [_line, stamp] = Regex.run(~r/DTSTAMP:(\d{8}T\d{6}Z)/, ical)
      assert {:ok, stamped_at, 0} = DateTime.from_iso8601(stamp, Calendar.ISO, :basic)
      assert DateTime.diff(DateTime.utc_now(), stamped_at) in 0..5
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

    test "includes organizer with SCHEDULE-AGENT=CLIENT when provided" do
      event_data = %{
        summary: "Meeting",
        organizer: "organizer@example.com",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(
               ical,
               "ORGANIZER;SCHEDULE-AGENT=CLIENT:mailto:organizer@example.com"
             )
    end

    # Issue #41: Zimbra (and other scheduling-aware CalDAV servers) strip
    # `SCHEDULE-AGENT` on ingest and run iTIP for any event that carries an
    # ATTENDEE block, duplicating Tymeslot's own notification email. The
    # only reliable fix is to omit ATTENDEE entirely on the write path and
    # surface the attendees via the (non-scheduling) CONTACT property.
    test "emits CONTACT (never ATTENDEE) for each attendee" do
      event_data = %{
        summary: "Meeting",
        attendees: ["john@example.com", "jane@example.com"],
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "ATTENDEE")
      assert String.contains?(ical, "CONTACT:john@example.com")
      assert String.contains?(ical, "CONTACT:jane@example.com")
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

    test "emits a CONFERENCE property when conference_url is provided" do
      event_data = %{
        summary: "Video Meeting",
        conference_url: "https://meet.example.com/abc",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical =
        "uid-conf" |> ICalBuilder.build_simple_event(event_data) |> String.replace("\r\n ", "")

      assert String.contains?(
               ical,
               "CONFERENCE;VALUE=URI;FEATURE=VIDEO:https://meet.example.com/abc"
             )
    end

    test "omits CONFERENCE when no conference_url is provided" do
      event_data = %{
        summary: "Plain",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event("uid-noconf", event_data)

      refute String.contains?(ical, "CONFERENCE")
    end

    test "emits TRANSP:TRANSPARENT when transparency is transparent" do
      event_data = %{
        summary: "Free Time",
        transparency: :transparent,
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event("uid-free", event_data)

      assert String.contains?(ical, "TRANSP:TRANSPARENT")
    end

    # Regression: prior to v0.100.0, build_simple_event/2 emitted neither
    # ORGANIZER nor ATTENDEE. The v0.100.0 refactor added ATTENDEE but not
    # ORGANIZER, which caused scheduling-aware CalDAV servers (Zimbra,
    # Nextcloud/Sabre, Apple iCloud) to inject their own ORGANIZER and fire
    # the iTIP pipeline — duplicating every invitation. The RFC 6638 §7.1
    # fix is `SCHEDULE-AGENT=CLIENT` on both properties.
    test "emits ORGANIZER with SCHEDULE-AGENT=CLIENT when organizer_email is present" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        organizer_name: "Host Person",
        organizer_email: "host@example.com"
      }

      ical = ICalBuilder.build_simple_event("uid-1", event_data)

      assert String.contains?(
               ical,
               "ORGANIZER;SCHEDULE-AGENT=CLIENT;CN=Host Person:mailto:host@example.com"
             )
    end

    test "omits CN from ORGANIZER when organizer_name is missing" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        organizer_email: "host@example.com"
      }

      ical = ICalBuilder.build_simple_event("uid-2", event_data)

      assert String.contains?(ical, "ORGANIZER;SCHEDULE-AGENT=CLIENT:mailto:host@example.com")
    end

    test "does not emit ORGANIZER when organizer_email is missing" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event("uid-3", event_data)

      refute String.contains?(ical, "ORGANIZER")
    end

    # Issue #41: Zimbra strips `SCHEDULE-AGENT` on ingest and auto-iTIPs any
    # event with an ATTENDEE block — empirically confirmed against a real
    # Zimbra instance. Tymeslot now surfaces the attendee via CONTACT and
    # the description instead. Do not re-introduce ATTENDEE on the CalDAV
    # write path.
    test "emits CONTACT (never ATTENDEE) when attendee_email is present" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        attendee_name: "Guest Person",
        attendee_email: "guest@example.com"
      }

      ical = ICalBuilder.build_simple_event("uid-4", event_data)

      refute String.contains?(ical, "ATTENDEE")
      assert String.contains?(ical, "CONTACT:Guest Person <guest@example.com>")
    end

    test "emits CONTACT without name when attendee_name is missing" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        attendee_email: "guest@example.com"
      }

      ical = ICalBuilder.build_simple_event("uid-5", event_data)

      refute String.contains?(ical, "ATTENDEE")
      assert String.contains?(ical, "CONTACT:guest@example.com")
    end

    test "emits neither ATTENDEE nor CONTACT when attendee data is absent" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event("uid-6", event_data)

      refute String.contains?(ical, "ATTENDEE")
      refute String.contains?(ical, "CONTACT:")
    end

    # Reminders are synced to the provider as VALARMs; the CalDAV write path
    # goes through build_simple_event/2, so the VALARM block must be wired in
    # there (build_event/1 already emits it). The canonical reminder shape is
    # `%{method: :popup | :email, minutes_before: integer}`.
    test "emits a VALARM (ACTION:DISPLAY) for a :popup reminder" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        reminders: [%{method: :popup, minutes_before: 10}]
      }

      ical = ICalBuilder.build_simple_event("uid-rem-1", event_data)

      assert String.contains?(ical, "BEGIN:VALARM")
      assert String.contains?(ical, "TRIGGER:-PT10M")
      assert String.contains?(ical, "ACTION:DISPLAY")
      assert String.contains?(ical, "END:VALARM")
    end

    test "maps an :email reminder method to ACTION:EMAIL" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        reminders: [%{method: :email, minutes_before: 30}]
      }

      ical = ICalBuilder.build_simple_event("uid-rem-2", event_data)

      assert String.contains?(ical, "TRIGGER:-PT30M")
      assert String.contains?(ical, "ACTION:EMAIL")
    end

    test "emits one VALARM per reminder" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        reminders: [
          %{method: :popup, minutes_before: 10},
          %{method: :email, minutes_before: 1440}
        ]
      }

      ical = ICalBuilder.build_simple_event("uid-rem-3", event_data)

      valarm_count =
        ical |> String.split("BEGIN:VALARM") |> length() |> Kernel.-(1)

      assert valarm_count == 2
      assert String.contains?(ical, "TRIGGER:-PT10M")
      assert String.contains?(ical, "TRIGGER:-PT1440M")
    end

    test "emits no VALARM when reminders are absent" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event("uid-rem-4", event_data)

      refute String.contains?(ical, "BEGIN:VALARM")
    end

    # Recurrence rules are synced via the CalDAV write path, which goes through
    # build_simple_event/2, so the RRULE line must be emitted from the canonical
    # `recurrence_rule` field.
    test "emits an RRULE line for the recurrence_rule field" do
      event_data = %{
        summary: "Standup",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 10:15:00Z],
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE,FR"
      }

      ical = ICalBuilder.build_simple_event("uid-rrule-1", event_data)

      assert String.contains?(ical, "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR")
    end

    test "strips an existing RRULE: prefix so it is not doubled" do
      event_data = %{
        summary: "Standup",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 10:15:00Z],
        recurrence_rule: "RRULE:FREQ=DAILY"
      }

      ical = ICalBuilder.build_simple_event("uid-rrule-2", event_data)

      assert String.contains?(ical, "RRULE:FREQ=DAILY")
      refute String.contains?(ical, "RRULE:RRULE:")
    end

    test "emits no RRULE line when recurrence_rule is absent" do
      event_data = %{
        summary: "Once",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event("uid-rrule-3", event_data)

      refute String.contains?(ical, "RRULE:")
    end
  end

  describe "build_event/1 — reminder VALARM shape" do
    test "reads the :method key (popup → DISPLAY) for the VALARM ACTION" do
      ical =
        ICalBuilder.build_event(%{
          summary: "Reminder Meeting",
          start_time: ~U[2024-01-15 10:00:00Z],
          end_time: ~U[2024-01-15 11:00:00Z],
          reminders: [%{method: :popup, minutes_before: 10}]
        })

      assert String.contains?(ical, "BEGIN:VALARM")
      assert String.contains?(ical, "TRIGGER:-PT10M")
      assert String.contains?(ical, "ACTION:DISPLAY")
    end

    test "maps :email method to ACTION:EMAIL" do
      ical =
        ICalBuilder.build_event(%{
          summary: "Reminder Meeting",
          start_time: ~U[2024-01-15 10:00:00Z],
          end_time: ~U[2024-01-15 11:00:00Z],
          reminders: [%{method: :email, minutes_before: 60}]
        })

      assert String.contains?(ical, "ACTION:EMAIL")
      assert String.contains?(ical, "TRIGGER:-PT60M")
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

  describe "build_event/1 — all-day DTEND exclusivity (issue #4)" do
    test "single-day all-day event: DTEND is start + 1 (not start == end)" do
      # When end_time == start_time (inclusive end passed in), DTEND must be +1.
      event_data = %{
        summary: "One-day event",
        start_time: ~D[2026-07-10],
        end_time: ~D[2026-07-10]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "DTSTART;VALUE=DATE:20260710")
      assert String.contains?(ical, "DTEND;VALUE=DATE:20260711")
      refute String.contains?(ical, "DTEND;VALUE=DATE:20260710")
    end

    test "multi-day all-day event with already-exclusive end is not double-incremented" do
      # end_time is already exclusive (start + 2 for a 2-night stay).
      event_data = %{
        summary: "Two-night stay",
        start_time: ~D[2026-07-10],
        end_time: ~D[2026-07-12]
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "DTSTART;VALUE=DATE:20260710")
      assert String.contains?(ical, "DTEND;VALUE=DATE:20260712")
    end
  end

  describe "build_simple_event/2 — all-day DTEND exclusivity (issue #4)" do
    test "single-day all-day: DTEND is bumped to start + 1 when end == start" do
      event_data = %{
        summary: "Single day",
        start_time: ~D[2026-07-10],
        end_time: ~D[2026-07-10]
      }

      ical = ICalBuilder.build_simple_event("uid-allday-1", event_data)

      assert String.contains?(ical, "DTSTART;VALUE=DATE:20260710")
      assert String.contains?(ical, "DTEND;VALUE=DATE:20260711")
    end

    test "multi-day all-day: already-exclusive end is not double-incremented" do
      event_data = %{
        summary: "Multi day",
        start_time: ~D[2026-07-10],
        end_time: ~D[2026-07-12]
      }

      ical = ICalBuilder.build_simple_event("uid-allday-2", event_data)

      assert String.contains?(ical, "DTEND;VALUE=DATE:20260712")
    end
  end
end
