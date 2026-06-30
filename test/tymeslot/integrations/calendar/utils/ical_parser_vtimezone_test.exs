defmodule Tymeslot.Integrations.Calendar.ICalParserVTimezoneTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalParser

  # Some calendar clients (notably Outlook exporting to CalDAV via Nextcloud)
  # emit non-IANA TZIDs — "Customized Time Zone", a bare numeric "1" — and bundle
  # the offset rules inline as a VTIMEZONE component (RFC 5545 §3.6.5). Before
  # VTIMEZONE parsing, these fell back to UTC, storing busy blocks 1–2 hours off
  # and corrupting availability. The bundled definitions observed in production
  # are Central European (CET/CEST), so summer events are UTC+2 and winter
  # UTC+1. Offset-style TZIDs like "GMT+0200" carry no VTIMEZONE and are resolved
  # by `Timezones.sanitize/1` mapping them to Etc/GMT zones instead.

  # The exact STANDARD/DAYLIGHT block Nextcloud served for integration 36.
  @cet_vtimezone """
  BEGIN:STANDARD
  DTSTART:16010101T030000
  TZOFFSETFROM:+0200
  TZOFFSETTO:+0100
  RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10
  END:STANDARD
  BEGIN:DAYLIGHT
  DTSTART:16010101T020000
  TZOFFSETFROM:+0100
  TZOFFSETTO:+0200
  RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3
  END:DAYLIGHT\
  """

  defp ical(vtimezones, vevents) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//EN
    #{vtimezones}
    #{vevents}
    END:VCALENDAR
    """
  end

  describe "parse/1 with a VTIMEZONE-defined custom TZID" do
    test "resolves a summer 'Customized Time Zone' event via its CEST (UTC+2) offset" do
      content =
        ical(
          "BEGIN:VTIMEZONE\nTZID:Customized Time Zone\n#{@cet_vtimezone}\nEND:VTIMEZONE",
          """
          BEGIN:VEVENT
          UID:summer@example.com
          DTSTART;TZID=Customized Time Zone:20250523T200000
          DTEND;TZID=Customized Time Zone:20250523T223000
          END:VEVENT
          """
        )

      assert {:ok, [event]} = ICalParser.parse(content)
      assert event.start_time == ~U[2025-05-23 18:00:00Z]
      assert event.end_time == ~U[2025-05-23 20:30:00Z]
    end

    test "resolves a winter 'Customized Time Zone' event via its CET (UTC+1) offset" do
      content =
        ical(
          "BEGIN:VTIMEZONE\nTZID:Customized Time Zone\n#{@cet_vtimezone}\nEND:VTIMEZONE",
          """
          BEGIN:VEVENT
          UID:winter@example.com
          DTSTART;TZID=Customized Time Zone:20260201T200000
          DTEND;TZID=Customized Time Zone:20260201T220000
          END:VEVENT
          """
        )

      assert {:ok, [event]} = ICalParser.parse(content)
      assert event.start_time == ~U[2026-02-01 19:00:00Z]
      assert event.end_time == ~U[2026-02-01 21:00:00Z]
    end

    test "resolves a numeric TZID with a leading space (sanitises to '1')" do
      content =
        ical(
          "BEGIN:VTIMEZONE\nTZID: 1\n#{@cet_vtimezone}\nEND:VTIMEZONE",
          """
          BEGIN:VEVENT
          UID:numeric@example.com
          DTSTART;TZID= 1:20250523T200000
          END:VEVENT
          """
        )

      assert {:ok, [event]} = ICalParser.parse(content)
      assert event.start_time == ~U[2025-05-23 18:00:00Z]
    end

    test "a real IANA TZID ignores any same-named VTIMEZONE and uses the tz database" do
      # Even with a (deliberately wrong) bundled VTIMEZONE, the database wins.
      content =
        ical(
          "BEGIN:VTIMEZONE\nTZID:Europe/Berlin\n#{@cet_vtimezone}\nEND:VTIMEZONE",
          """
          BEGIN:VEVENT
          UID:iana@example.com
          DTSTART;TZID=Europe/Berlin:20250523T200000
          END:VEVENT
          """
        )

      assert {:ok, [event]} = ICalParser.parse(content)
      # Berlin in May is CEST (UTC+2) — same instant, via the database not the block.
      assert event.start_time == ~U[2025-05-23 18:00:00Z]
    end
  end

  describe "parse/1 with an offset-style TZID and no VTIMEZONE" do
    test "resolves 'GMT+0200' via the Etc/GMT-2 fallback (UTC+2)" do
      content =
        ical("", """
        BEGIN:VEVENT
        UID:gmt@example.com
        DTSTART;TZID=GMT+0200:20210721T210000
        DTEND;TZID=GMT+0200:20210721T230000
        END:VEVENT
        """)

      assert {:ok, [event]} = ICalParser.parse(content)
      assert event.start_time == ~U[2021-07-21 19:00:00Z]
      assert event.end_time == ~U[2021-07-21 21:00:00Z]
    end
  end

  describe "parse/1 when a custom TZID has no resolvable definition" do
    test "falls back to UTC for an unknown TZID with no VTIMEZONE" do
      content =
        ical("", """
        BEGIN:VEVENT
        UID:orphan@example.com
        DTSTART;TZID=Totally Made Up:20250523T200000
        END:VEVENT
        """)

      assert {:ok, [event]} = ICalParser.parse(content)
      # No VTIMEZONE, not a known zone → naive treated as UTC (unchanged behaviour).
      assert event.start_time == ~U[2025-05-23 20:00:00Z]
    end
  end
end
