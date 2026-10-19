defmodule Tymeslot.Integrations.Calendar.ICalParserTextTest do
  @moduledoc """
  How the parser decodes escaped text values (RFC 5545 §3.3.11): a
  description or location with backslashes in it reads back as written, and
  the text Tymeslot writes (`ICalBuilder.Format.escape_text/1`) survives the
  round trip, so it is not corrupted and written back on the next edit.
  """
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalParser

  describe "parse/1" do
    test "reads an escaped backslash before an n as a backslash, and \\N as a line break" do
      ical_content = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:paths@example.com
      DTSTART:20300115T100000Z
      DTEND:20300115T110000Z
      SUMMARY:Notes
      LOCATION:C:\\\\new\\\\notes
      DESCRIPTION:First\\NSecond\\nThird
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.location == "C:\\new\\notes"
      assert event.description == "First\nSecond\nThird"
    end

    test "reads back exactly the text Tymeslot writes" do
      text = "C:\\new\\path; one, two\nnext line \\n not a break"

      ical_content =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:round-trip@example.com",
            "DTSTART:20300115T100000Z",
            "DTEND:20300115T110000Z",
            "SUMMARY:Round trip",
            "DESCRIPTION:" <> Format.escape_text(text),
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        )

      assert {:ok, [event]} = ICalParser.parse(ical_content)
      assert event.description == text
    end
  end
end
