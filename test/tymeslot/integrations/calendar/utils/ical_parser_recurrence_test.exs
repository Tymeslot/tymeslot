defmodule Tymeslot.Integrations.Calendar.ICalParserRecurrenceTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalParser

  describe "parse/1" do
    test "parses RRULE property" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:recurring@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Weekly Standup
      RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.recurrence_rule == "FREQ=WEEKLY;BYDAY=MO,WE,FR"
    end

    test "returns nil recurrence_rule when RRULE is absent" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:one-off@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:One-off Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert is_nil(event.recurrence_rule)
    end

    test "parses RECURRENCE-ID for a recurring event instance" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:recurring@example.com
      RECURRENCE-ID:20300115T100000Z
      DTSTART:20300115T110000Z
      DTEND:20300115T120000Z
      SUMMARY:Moved Instance
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.recurrence_id == "20300115T100000Z"
      assert is_nil(event.recurrence_id_range)
    end

    test "captures RANGE=THISANDFUTURE on RECURRENCE-ID" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:recurring@example.com
      RECURRENCE-ID;RANGE=THISANDFUTURE:20300115T100000Z
      DTSTART:20300115T110000Z
      DTEND:20300115T120000Z
      SUMMARY:Moved This And Future
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.recurrence_id == "20300115T100000Z"
      assert event.recurrence_id_range == :this_and_future
    end

    test "returns nil recurrence_id when RECURRENCE-ID is absent" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:standalone@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Standalone
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert is_nil(event.recurrence_id)
    end

    test "parses EXDATE property with single date" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:exdate-test@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Weekly with exception
      RRULE:FREQ=WEEKLY
      EXDATE:20300122T100000Z
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert [~U[2030-01-22 10:00:00Z]] = event.exdates
    end

    test "parses EXDATE property with multiple dates" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:exdate-multi@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Weekly with exceptions
      RRULE:FREQ=WEEKLY
      EXDATE:20300122T100000Z,20300129T100000Z
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert length(event.exdates) == 2
    end

    test "parses multiple EXDATE lines" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:exdate-lines@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Weekly
      RRULE:FREQ=WEEKLY
      EXDATE:20300122T100000Z
      EXDATE:20300129T100000Z
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert length(event.exdates) == 2
    end

    test "returns empty list when EXDATE is absent" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:no-exdate@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:No exceptions
      RRULE:FREQ=WEEKLY
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.exdates == []
    end

    test "parses EXDATE with TZID parameter" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:exdate-tz@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Weekly with TZ exception
      RRULE:FREQ=WEEKLY
      EXDATE;TZID=Europe/Amsterdam:20300122T110000
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert [exdate] = event.exdates
      # Amsterdam is UTC+1 in January, so 11:00 local = 10:00 UTC
      assert exdate == ~U[2030-01-22 10:00:00Z]
    end

    test "handles timezone parameter in DTSTART" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:tz-event@example.com
      DTSTART;TZID=America/New_York:20300115T100000
      DTEND;TZID=America/New_York:20300115T110000
      SUMMARY:Event with Timezone
      END:VEVENT
      END:VCALENDAR
      """

      # Parser should handle TZID parameter
      result = ICalParser.parse(ical_content)
      assert match?({:ok, _}, result)
    end
  end
end
