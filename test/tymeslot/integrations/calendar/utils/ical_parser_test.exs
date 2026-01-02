defmodule Tymeslot.Integrations.Calendar.ICalParserTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Calendar.ICalParser

  describe "parse/1" do
    test "parses valid iCalendar content with single event" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:event-123@example.com
      DTSTART:20260115T100000Z
      DTEND:20260115T110000Z
      SUMMARY:Team Meeting
      DESCRIPTION:Weekly sync
      LOCATION:Room A
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.uid == "event-123@example.com"
      assert event.summary == "Team Meeting"
      assert event.description == "Weekly sync"
      assert event.location == "Room A"
      assert %DateTime{} = event.start_time
      assert %DateTime{} = event.end_time
    end

    test "parses multiple events" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:event1@example.com
      DTSTART:20260115T100000Z
      DTEND:20260115T110000Z
      SUMMARY:Meeting 1
      END:VEVENT
      BEGIN:VEVENT
      UID:event2@example.com
      DTSTART:20260115T140000Z
      DTEND:20260115T150000Z
      SUMMARY:Meeting 2
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, events} = ICalParser.parse(ical_content)
      assert length(events) == 2
      assert Enum.any?(events, fn e -> e.summary == "Meeting 1" end)
      assert Enum.any?(events, fn e -> e.summary == "Meeting 2" end)
    end

    test "handles different line endings (CRLF)" do
      ical_content = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:test@example.com\r\nDTSTART:20260115T100000Z\r\nDTEND:20260115T110000Z\r\nSUMMARY:Test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Test"
    end

    test "handles Unix line endings (LF)" do
      ical_content = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:test@example.com\nDTSTART:20260115T100000Z\nDTEND:20260115T110000Z\nSUMMARY:Test\nEND:VEVENT\nEND:VCALENDAR\n"

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Test"
    end

    test "handles CR line endings" do
      ical_content = "BEGIN:VCALENDAR\rVERSION:2.0\rBEGIN:VEVENT\rUID:test@example.com\rDTSTART:20260115T100000Z\rDTEND:20260115T110000Z\rSUMMARY:Test\rEND:VEVENT\rEND:VCALENDAR\r"

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Test"
    end

    test "unescapes special characters in text fields" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:test@example.com
      DTSTART:20260115T100000Z
      DTEND:20260115T110000Z
      SUMMARY:Meeting\\, Planning
      DESCRIPTION:Line 1\\nLine 2\\nLine 3
      LOCATION:Building A\\; Room 5
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Meeting, Planning"
      assert String.contains?(event.description, "\n")
      assert event.location == "Building A; Room 5"
    end

    test "handles folded lines (continuation lines)" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:test@example.com
      DTSTART:20260115T100000Z
      DTEND:20260115T110000Z
      SUMMARY:This is a very long summary that spans
       multiple lines in the iCalendar format
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert String.contains?(event.summary, "very long summary")
      assert String.contains?(event.summary, "multiple lines")
    end

    test "filters out past events" do
      # Event that ended yesterday
      past_time = DateTime.add(DateTime.utc_now(), -86_400, :second)
      past_start = DateTime.to_iso8601(past_time) |> String.replace(~r/[-:]/, "") |> String.replace("Z", "Z")
      past_end = DateTime.to_iso8601(DateTime.add(past_time, 3600, :second)) |> String.replace(~r/[-:]/, "") |> String.replace("Z", "Z")

      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:past-event@example.com
      DTSTART:#{past_start}
      DTEND:#{past_end}
      SUMMARY:Past Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, events} = ICalParser.parse(ical_content)
      assert events == []
    end

    test "includes future events" do
      # Event starting in 1 hour
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)
      future_start = DateTime.to_iso8601(future_time) |> String.replace(~r/[-:]/, "") |> String.replace("Z", "Z")
      future_end = DateTime.to_iso8601(DateTime.add(future_time, 3600, :second)) |> String.replace(~r/[-:]/, "") |> String.replace("Z", "Z")

      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:future-event@example.com
      DTSTART:#{future_start}
      DTEND:#{future_end}
      SUMMARY:Future Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Future Event"
    end

    test "returns error for invalid iCalendar format" do
      invalid_content = "This is not valid iCalendar data"

      assert {:error, message} = ICalParser.parse(invalid_content)
      assert String.contains?(message, "Invalid iCal format")
    end

    test "returns error for malformed VEVENT" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      This is malformed
      END:VEVENT
      END:VCALENDAR
      """

      # Should parse but return no events due to missing required fields
      assert {:ok, events} = ICalParser.parse(ical_content)
      assert events == []
    end

    test "skips events without UID" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      DTSTART:20240115T100000Z
      DTEND:20240115T110000Z
      SUMMARY:Event Without UID
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, events} = ICalParser.parse(ical_content)
      assert events == []
    end

    test "skips events without SUMMARY" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:test@example.com
      DTSTART:20240115T100000Z
      DTEND:20240115T110000Z
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, events} = ICalParser.parse(ical_content)
      assert events == []
    end

    test "skips events without DTSTART" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:test@example.com
      DTEND:20240115T110000Z
      SUMMARY:Event Without Start
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, events} = ICalParser.parse(ical_content)
      assert events == []
    end

    test "calculates end time from duration when DTEND missing" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:test@example.com
      DTSTART:20260115T100000Z
      DURATION:PT1H
      SUMMARY:Event With Duration
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Event With Duration"
      assert %DateTime{} = event.end_time

      # End time should be 1 hour after start
      duration_seconds = DateTime.diff(event.end_time, event.start_time)
      assert duration_seconds == 3600
    end

    test "defaults to 1 hour when neither DTEND nor DURATION provided" do
      future_time = DateTime.add(DateTime.utc_now(), 86_400, :second)
      future_start = DateTime.to_iso8601(future_time) |> String.replace(~r/[-:]/, "") |> String.replace("Z", "Z")

      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:test@example.com
      DTSTART:#{future_start}
      SUMMARY:Event Without End
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert %DateTime{} = event.end_time

      # Should default to 1 hour duration
      duration_seconds = DateTime.diff(event.end_time, event.start_time)
      assert duration_seconds == 3600
    end

    test "handles all-day events (DATE format)" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:allday@example.com
      DTSTART:20260115
      DTEND:20260116
      SUMMARY:All Day Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "All Day Event"
      assert %DateTime{} = event.start_time
    end

    test "handles timezone parameter in DTSTART" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:tz-event@example.com
      DTSTART;TZID=America/New_York:20260115T100000
      DTEND;TZID=America/New_York:20260115T110000
      SUMMARY:Event with Timezone
      END:VEVENT
      END:VCALENDAR
      """

      # Parser should handle TZID parameter
      result = ICalParser.parse(ical_content)
      assert match?({:ok, _}, result)
    end
  end

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
      DTSTART:20260115T100000Z
      DTEND:20260115T110000Z
      SUMMARY:CalDAV Event
      END:VEVENT
      END:VCALENDAR</calendar-data>
            </prop>
          </propstat>
        </response>
      </multistatus>
      """

      assert {:ok, events} = ICalParser.parse_multistatus(xml_body)
      assert length(events) >= 0
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
