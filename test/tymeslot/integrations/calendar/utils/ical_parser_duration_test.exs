defmodule Tymeslot.Integrations.Calendar.ICalParserDurationTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalParser

  # An event with a DURATION and no DTEND: RFC 5545 §3.3.6 makes a duration's
  # days nominal (calendar days) and its time part exact (elapsed time).

  describe "parse/1 with DURATION in place of DTEND" do
    test "calculates end date from DURATION when DTEND missing on all-day event" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:allday-duration@example.com
      DTSTART;VALUE=DATE:20300115
      DURATION:P3D
      SUMMARY:Three Day Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Three Day Event"
      assert %Date{} = event.start_time
      assert %Date{} = event.end_time
      assert event.start_time == ~D[2030-01-15]
      assert event.end_time == ~D[2030-01-18]
    end

    test "rounds a DURATION's time part up to a further day on an all-day event" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:allday-part-day@example.com
      DTSTART;VALUE=DATE:20300115
      DURATION:P1DT12H
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.end_time == ~D[2030-01-17]
    end

    test "counts a time-only DURATION of several days in whole days on an all-day event" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:allday-hours@example.com
      DTSTART;VALUE=DATE:20300115
      DURATION:PT48H
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.end_time == ~D[2030-01-17]
    end

    # RFC 5545 §3.3.6: days are nominal. 2030-03-31 is the EU spring-forward
    # date, so 09:00 CET plus a day is 09:00 CEST, 23 elapsed hours later.
    test "adds a DURATION's days in DTSTART's wall clock across a DST change" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:dst-duration@example.com
      DTSTART;TZID=Europe/Berlin:20300330T090000
      DURATION:P1DT2H
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.start_time == ~U[2030-03-30 08:00:00Z]
      assert event.end_time == ~U[2030-03-31 09:00:00Z]
    end
  end
end
