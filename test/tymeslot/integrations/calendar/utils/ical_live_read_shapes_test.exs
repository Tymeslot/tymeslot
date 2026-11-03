defmodule Tymeslot.Integrations.Calendar.ICalLiveReadShapesTest do
  @moduledoc """
  Shapes other clients leave on a CalDAV calendar, read the way booking
  availability reads one: parsed, expanded over the range by
  `ICalNormaliser.expand_occurrences/3`, then filtered by
  `CalendarEvent.blocking?/1`. Each was found failing by a live
  `mix calendar_audit` run against a CalDAV server.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  defp busy_starts(ics, range_start, range_end) do
    {:ok, raw_events} = ICalParser.parse(ics)

    raw_events
    |> ICalNormaliser.expand_occurrences(range_start, range_end)
    |> Enum.filter(&CalendarEvent.blocking?/1)
    |> Enum.map(& &1.start_time)
    |> Enum.sort(DateTime)
  end

  defp series(lines) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//EN
    #{Enum.join(lines, "\n")}
    END:VCALENDAR
    """
  end

  test "an occurrence cancelled by its override frees its slot" do
    ics =
      series([
        "BEGIN:VEVENT",
        "UID:cancelled-override",
        "DTSTART:20261105T100000Z",
        "DTEND:20261105T110000Z",
        "RRULE:FREQ=DAILY;COUNT=3",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:cancelled-override",
        "RECURRENCE-ID:20261106T100000Z",
        "DTSTART:20261106T100000Z",
        "DTEND:20261106T110000Z",
        "STATUS:CANCELLED",
        "END:VEVENT"
      ])

    assert busy_starts(ics, ~U[2026-11-01 00:00:00Z], ~U[2026-11-10 00:00:00Z]) ==
             [~U[2026-11-05 10:00:00Z], ~U[2026-11-07 10:00:00Z]]
  end

  test "RDATE adds occurrences beside the rule's" do
    ics =
      series([
        "BEGIN:VEVENT",
        "UID:rdate",
        "DTSTART:20261105T100000Z",
        "DTEND:20261105T110000Z",
        "RRULE:FREQ=DAILY;COUNT=2",
        "RDATE:20261108T100000Z,20261110T100000Z",
        "END:VEVENT"
      ])

    assert busy_starts(ics, ~U[2026-11-01 00:00:00Z], ~U[2026-11-15 00:00:00Z]) ==
             [
               ~U[2026-11-05 10:00:00Z],
               ~U[2026-11-06 10:00:00Z],
               ~U[2026-11-08 10:00:00Z],
               ~U[2026-11-10 10:00:00Z]
             ]
  end

  test "an RDATE outside the range is not offered" do
    ics =
      series([
        "BEGIN:VEVENT",
        "UID:rdate-outside",
        "DTSTART:20261105T100000Z",
        "DTEND:20261105T110000Z",
        "RRULE:FREQ=DAILY;COUNT=1",
        "RDATE:20261201T100000Z",
        "END:VEVENT"
      ])

    assert busy_starts(ics, ~U[2026-11-01 00:00:00Z], ~U[2026-11-15 00:00:00Z]) ==
             [~U[2026-11-05 10:00:00Z]]
  end

  test "an EXDATE;VALUE=DATE excludes a timed series' occurrence on that day" do
    ics =
      series([
        "BEGIN:VEVENT",
        "UID:date-exdate",
        "DTSTART:20261105T100000Z",
        "DTEND:20261105T110000Z",
        "RRULE:FREQ=DAILY;COUNT=3",
        "EXDATE;VALUE=DATE:20261106",
        "END:VEVENT"
      ])

    assert busy_starts(ics, ~U[2026-11-01 00:00:00Z], ~U[2026-11-10 00:00:00Z]) ==
             [~U[2026-11-05 10:00:00Z], ~U[2026-11-07 10:00:00Z]]
  end

  # The day is the series' own: 00:30 in Ljubljana on the 6th is 23:30 UTC on
  # the 5th, and an EXDATE for the 6th must still name it.
  test "the EXDATE's day is read in the series' zone" do
    ics =
      series([
        "BEGIN:VEVENT",
        "UID:date-exdate-zone",
        "DTSTART;TZID=Europe/Ljubljana:20261105T003000",
        "DTEND;TZID=Europe/Ljubljana:20261105T013000",
        "RRULE:FREQ=DAILY;COUNT=3",
        "EXDATE;VALUE=DATE:20261106",
        "END:VEVENT"
      ])

    assert busy_starts(ics, ~U[2026-11-01 00:00:00Z], ~U[2026-11-10 00:00:00Z]) ==
             [~U[2026-11-04 23:30:00Z], ~U[2026-11-06 23:30:00Z]]
  end

  test "an occurrence still running when the range starts is read" do
    ics =
      series([
        "BEGIN:VEVENT",
        "UID:running",
        "DTSTART:20261105T100000Z",
        "DTEND:20261107T100000Z",
        "RRULE:FREQ=WEEKLY;COUNT=3",
        "END:VEVENT"
      ])

    assert busy_starts(ics, ~U[2026-11-06 00:00:00Z], ~U[2026-11-07 00:00:00Z]) ==
             [~U[2026-11-05 10:00:00Z]]
  end

  describe "RecurrenceExpander.expand/4" do
    test "a long-running series skipped ahead still keeps the occurrence that overlaps the range" do
      event = %{
        start_time: ~U[2020-01-06 10:00:00Z],
        end_time: ~U[2020-01-08 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY"
      }

      starts =
        event
        |> RecurrenceExpander.expand(~U[2026-11-04 00:00:00Z], ~U[2026-11-05 00:00:00Z])
        |> Enum.map(& &1.start_time)

      # Mondays at 10:00, two days long: the 2 November occurrence runs until
      # the 4th and overlaps the range, which starts on a Wednesday.
      assert starts == [~U[2026-11-02 10:00:00Z]]
    end

    test "an occurrence that ends exactly as the range starts is not read" do
      event = %{
        start_time: ~U[2026-11-05 10:00:00Z],
        end_time: ~U[2026-11-05 11:00:00Z],
        recurrence_rule: "FREQ=DAILY;COUNT=3"
      }

      starts =
        event
        |> RecurrenceExpander.expand(~U[2026-11-06 11:00:00Z], ~U[2026-11-07 00:00:00Z])
        |> Enum.map(& &1.start_time)

      assert starts == []
    end
  end
end
