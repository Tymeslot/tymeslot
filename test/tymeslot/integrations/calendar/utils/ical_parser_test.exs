defmodule Tymeslot.Integrations.Calendar.ICalParserTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalParser

  describe "parse/1" do
    test "parses valid iCalendar content with single event" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:event-123@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
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
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Meeting 1
      END:VEVENT
      BEGIN:VEVENT
      UID:event2@example.com
      DTSTART:20300115T140000Z
      DTEND:20300115T150000Z
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
      ical_content =
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:test@example.com\r\nDTSTART:20300115T100000Z\r\nDTEND:20300115T110000Z\r\nSUMMARY:Test\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Test"
    end

    test "handles Unix line endings (LF)" do
      ical_content =
        "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:test@example.com\nDTSTART:20300115T100000Z\nDTEND:20300115T110000Z\nSUMMARY:Test\nEND:VEVENT\nEND:VCALENDAR\n"

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Test"
    end

    test "handles CR line endings" do
      ical_content =
        "BEGIN:VCALENDAR\rVERSION:2.0\rBEGIN:VEVENT\rUID:test@example.com\rDTSTART:20300115T100000Z\rDTEND:20300115T110000Z\rSUMMARY:Test\rEND:VEVENT\rEND:VCALENDAR\r"

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Test"
    end

    test "unescapes special characters in text fields" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:test@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
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
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:This is a very long summary that spans
       multiple lines in the iCalendar format
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert String.contains?(event.summary, "very long summary")
      assert String.contains?(event.summary, "multiple lines")
    end

    test "includes past events" do
      # The parser does not filter by time — callers handle date-range filtering.
      past_time = DateTime.add(DateTime.utc_now(), -86_400, :second)
      past_start = format_ical_datetime(past_time)
      past_end = format_ical_datetime(DateTime.add(past_time, 3600, :second))

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

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.uid == "past-event@example.com"
      assert event.summary == "Past Event"
    end

    test "includes future events" do
      # Event starting in 1 hour
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      future_start =
        DateTime.to_iso8601(future_time)
        |> String.replace(~r/[-:]/, "")
        |> String.replace("Z", "Z")

      future_end =
        DateTime.to_iso8601(DateTime.add(future_time, 3600, :second))
        |> String.replace(~r/[-:]/, "")
        |> String.replace("Z", "Z")

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

    test "includes events without SUMMARY" do
      future = DateTime.add(DateTime.utc_now(), 86_400, :second)
      future_start = format_ical_datetime(future)
      future_end = format_ical_datetime(DateTime.add(future, 3600, :second))

      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:test@example.com
      DTSTART:#{future_start}
      DTEND:#{future_end}
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.uid == "test@example.com"
      assert event.summary == nil
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
      DTSTART:20300115T100000Z
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

      future_start =
        DateTime.to_iso8601(future_time)
        |> String.replace(~r/[-:]/, "")
        |> String.replace("Z", "Z")

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
      DTSTART:20300115
      DTEND:20300116
      SUMMARY:All Day Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "All Day Event"
      assert %Date{} = event.start_time
    end

    test "handles multi-day all-day events (DATE format spanning several days)" do
      ical_content = """
      BEGIN:VCALENDAR
      PRODID:Zimbra-Calendar-Provider
      VERSION:2.0
      METHOD:PUBLISH
      BEGIN:VEVENT
      UID:52482753-b5f0-4162-8c8f-64aab3a69c27
      SUMMARY:Congés
      DESCRIPTION:\\n
      ORGANIZER;CN=Daniel Berteaud:mailto:dani@lapiole.org
      DTSTART;VALUE=DATE:20260407
      DTEND;VALUE=DATE:20260411
      STATUS:CONFIRMED
      CLASS:PUBLIC
      X-MICROSOFT-CDO-ALLDAYEVENT:TRUE
      X-MICROSOFT-CDO-INTENDEDSTATUS:FREE
      TRANSP:TRANSPARENT
      LAST-MODIFIED:20260401T212004Z
      DTSTAMP:20260401T212004Z
      SEQUENCE:2
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.summary == "Congés"
      assert %Date{} = event.start_time
      assert %Date{} = event.end_time
      assert event.start_time == ~D[2026-04-07]
      assert event.end_time == ~D[2026-04-11]
      assert event.transparency == "transparent"
    end

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

    test "sets transparency to nil when TRANSP property is absent" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:no-transp@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Regular Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert is_nil(event.transparency)
    end

    test "parses TRANSP:TRANSPARENT for free events" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:free-event@example.com
      DTSTART:20300115T100000Z
      DTEND:20300116T000000Z
      SUMMARY:Free Holiday
      TRANSP:TRANSPARENT
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.transparency == "transparent"
    end

    test "parses TRANSP:OPAQUE for busy events" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:busy-event@example.com
      DTSTART:20300115T140000Z
      DTEND:20300115T150000Z
      SUMMARY:Busy Meeting
      TRANSP:OPAQUE
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.transparency == "opaque"
    end

    test "parses ATTENDEE properties into a list of attendee maps" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:attendee-event@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Team Standup
      ATTENDEE;CN=Alice Smith;PARTSTAT=ACCEPTED:mailto:alice@example.com
      ATTENDEE;CN=Bob Jones;PARTSTAT=DECLINED:mailto:bob@example.com
      ATTENDEE:mailto:carol@example.com
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert [alice, bob, carol] = event.attendees
      assert alice["email"] == "alice@example.com"
      assert alice["name"] == "Alice Smith"
      assert alice["status"] == "accepted"
      assert bob["email"] == "bob@example.com"
      assert bob["name"] == "Bob Jones"
      assert bob["status"] == "declined"
      assert carol["email"] == "carol@example.com"
      assert is_nil(carol["name"])
    end

    test "strips surrounding quotes from quoted CN names" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:quoted-cn@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Meeting
      ATTENDEE;CN="Doe, Jane";PARTSTAT=ACCEPTED:mailto:jane@example.com
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert [jane] = event.attendees
      assert jane["name"] == "Doe, Jane"
    end

    test "returns empty attendees list when no ATTENDEE properties are present" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:no-attendees@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Solo Event
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.attendees == []
    end
  end

  defp format_ical_datetime(dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
  end
end
