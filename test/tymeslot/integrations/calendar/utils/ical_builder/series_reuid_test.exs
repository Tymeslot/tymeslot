defmodule Tymeslot.Integrations.Calendar.ICalBuilder.SeriesReuidTest do
  @moduledoc """
  A recurring series copied under a new identifier (`ICalBuilder.Series.reuid/2`),
  as a move to another calendar writes it: the master and every override
  take the new `UID`, so the copy stays one series apart from the original,
  and nothing else in the document changes.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series

  # A series with everything a copy must carry as written: a VTIMEZONE, an
  # alarm with an identifier of its own (RFC 9074), a long folded line, an
  # X- property and an override of one occurrence.
  @document Enum.join(
              [
                "BEGIN:VCALENDAR",
                "VERSION:2.0",
                "PRODID:-//Example Corp.//Calendar 1.0//EN",
                "BEGIN:VTIMEZONE",
                "TZID:Europe/Berlin",
                "BEGIN:STANDARD",
                "DTSTART:19701025T030000",
                "TZOFFSETFROM:+0200",
                "TZOFFSETTO:+0100",
                "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU",
                "END:STANDARD",
                "END:VTIMEZONE",
                "BEGIN:VEVENT",
                "UID:standup@example.com",
                "DTSTAMP:20260901T090000Z",
                "DTSTART;TZID=Europe/Berlin:20261005T090000",
                "DTEND;TZID=Europe/Berlin:20261005T093000",
                "RRULE:FREQ=WEEKLY;BYDAY=MO",
                "EXDATE;TZID=Europe/Berlin:20261019T090000",
                "SUMMARY:Weekly standup",
                "DESCRIPTION:Agenda: what shipped last week\\, what ships this week\\, an",
                " d whatever is blocking either of them.",
                "X-EXAMPLE-COLOUR:tomato",
                "BEGIN:VALARM",
                "UID:alarm-1@example.com",
                "ACTION:DISPLAY",
                "TRIGGER:-PT15M",
                "END:VALARM",
                "END:VEVENT",
                "BEGIN:VEVENT",
                "UID:standup@example.com",
                "RECURRENCE-ID;TZID=Europe/Berlin:20261012T090000",
                "DTSTAMP:20260901T090000Z",
                "DTSTART;TZID=Europe/Berlin:20261012T140000",
                "DTEND;TZID=Europe/Berlin:20261012T143000",
                "SUMMARY:Weekly standup (afternoon)",
                "END:VEVENT",
                "END:VCALENDAR"
              ],
              "\r\n"
            ) <> "\r\n"

  test "every VEVENT takes the new UID and every other byte stays as written" do
    assert {:ok, copy} = Series.reuid(@document, "moved@tymeslot.com")

    assert copy ==
             String.replace(@document, "UID:standup@example.com", "UID:moved@tymeslot.com")
  end

  test "the master and the override both leave the original's identifier behind" do
    assert {:ok, copy} = Series.reuid(@document, "moved@tymeslot.com")

    uids = for "UID:" <> uid <- String.split(copy, "\r\n"), do: uid
    assert uids == ["moved@tymeslot.com", "alarm-1@example.com", "moved@tymeslot.com"]
  end

  test "a document holding no VEVENT is empty" do
    assert Series.reuid("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n", "x") == :empty
  end
end
