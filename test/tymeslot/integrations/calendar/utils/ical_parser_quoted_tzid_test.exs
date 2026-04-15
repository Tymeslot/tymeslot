defmodule Tymeslot.Integrations.Calendar.ICalParserQuotedTzidTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalParser

  # RFC 5545 §3.2.18 permits quoted parameter values. Zimbra, for example,
  # emits `DTSTART;TZID="Europe/Brussels":...` with the quotes. Without
  # stripping them, parsing falls back to UTC and produces a 1–2 hour
  # offset on the stored start/end times. Regression for GitHub issue #38.

  describe "parse/1 with quoted TZID parameter" do
    test "Brussels in summer (CEST, UTC+2)" do
      ical_content = ~s"""
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:quoted-tzid-summer@example.com
      DTSTART;TZID="Europe/Brussels":20300715T090000
      DTEND;TZID="Europe/Brussels":20300715T100000
      SUMMARY:Zimbra Quoted TZID (summer)
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.start_time == ~U[2030-07-15 07:00:00Z]
      assert event.end_time == ~U[2030-07-15 08:00:00Z]
    end

    test "Brussels in winter (CET, UTC+1)" do
      ical_content = ~s"""
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:quoted-tzid-winter@example.com
      DTSTART;TZID="Europe/Brussels":20300115T090000
      DTEND;TZID="Europe/Brussels":20300115T100000
      SUMMARY:Zimbra Quoted TZID (winter)
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.start_time == ~U[2030-01-15 08:00:00Z]
      assert event.end_time == ~U[2030-01-15 09:00:00Z]
    end
  end
end
