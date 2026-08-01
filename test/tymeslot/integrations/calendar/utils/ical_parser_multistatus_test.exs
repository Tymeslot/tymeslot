defmodule Tymeslot.Integrations.Calendar.ICalParserMultistatusTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalParser

  describe "parse_multistatus/1" do
    test "returns empty list for empty XML body" do
      assert {:ok, []} = ICalParser.parse_multistatus("")
    end

    test "returns empty list for whitespace-only XML" do
      assert {:ok, []} = ICalParser.parse_multistatus("   \n  \t  ")
    end

    test "parses CalDAV multistatus response with calendar data" do
      xml_body = """
      <?xml version="1.0"?>
      <multistatus xmlns="DAV:">
        <response>
          <href>/calendars/user/calendar/event1.ics</href>
          <propstat>
            <prop>
              <calendar-data>BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:event1@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:CalDAV Event
      END:VEVENT
      END:VCALENDAR</calendar-data>
            </prop>
          </propstat>
        </response>
      </multistatus>
      """

      assert {:ok, [event]} = ICalParser.parse_multistatus(xml_body)
      assert event.uid == "event1@example.com"
      assert event.summary == "CalDAV Event"
      assert event.start_time == ~U[2030-01-15 10:00:00Z]
      assert event.end_time == ~U[2030-01-15 11:00:00Z]
    end

    test "handles XML entities in calendar data" do
      xml_body = """
      <?xml version="1.0"?>
      <multistatus xmlns="DAV:">
        <response>
          <calendar-data>&lt;BEGIN:VCALENDAR&gt;</calendar-data>
        </response>
      </multistatus>
      """

      # Should unescape XML entities
      assert {:ok, _events} = ICalParser.parse_multistatus(xml_body)
    end
  end
end
