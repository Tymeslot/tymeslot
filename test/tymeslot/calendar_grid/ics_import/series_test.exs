defmodule Tymeslot.CalendarGrid.IcsImport.SeriesTest do
  @moduledoc """
  Covers how an `.ics` import carries a recurring series across: which
  occurrences it excludes, and how an override moving one occurrence, or
  that occurrence and every later one, changes what is written. Read through
  `IcsImport.plan/2`, the only way in.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.IcsImport
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Properties

  defp ics(vevents) do
    Enum.join(
      ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//EN"] ++ vevents ++ ["END:VCALENDAR"],
      "\r\n"
    )
  end

  defp vevent(lines), do: Enum.join(["BEGIN:VEVENT"] ++ lines ++ ["END:VEVENT"], "\r\n")

  defp timed(uid, summary, start, finish, extra) do
    vevent(["UID:#{uid}", "SUMMARY:#{summary}", "DTSTART:#{start}", "DTEND:#{finish}"] ++ extra)
  end

  defp plan!(content) do
    {:ok, plan} = IcsImport.plan(content)
    plan
  end

  describe "plan/2" do
    test "excludes a series' EXDATEs and moved occurrences, writing each move on its own" do
      plan =
        plan!(
          ics([
            timed("weekly@x", "Standup", "20261102T090000Z", "20261102T091500Z", [
              "RRULE:FREQ=WEEKLY;COUNT=10",
              "EXDATE:20261109T090000Z"
            ]),
            # The 16 November occurrence moved an hour later.
            timed("weekly@x", "Standup (late)", "20261116T100000Z", "20261116T101500Z", [
              "RECURRENCE-ID:20261116T090000Z"
            ]),
            # The 23 November occurrence was cancelled.
            timed("weekly@x", "Standup", "20261123T090000Z", "20261123T091500Z", [
              "RECURRENCE-ID:20261123T090000Z",
              "STATUS:CANCELLED"
            ])
          ])
        )

      assert [series, moved] = plan.events
      assert series.recurrence_rule =~ "FREQ=WEEKLY"

      assert Enum.sort(series.recurrence_exceptions, DateTime) == [
               ~U[2026-11-09 09:00:00Z],
               ~U[2026-11-16 09:00:00Z],
               ~U[2026-11-23 09:00:00Z]
             ]

      assert moved.summary == "Standup (late)"
      assert moved.start_time == ~U[2026-11-16 10:00:00Z]
      refute Map.has_key?(moved, :recurrence_rule)
      assert plan.series == 1
    end

    test "reads a wall-clock RECURRENCE-ID in the series' own zone" do
      plan =
        plan!(
          ics([
            vevent([
              "UID:berlin@x",
              "SUMMARY:Yoga",
              "DTSTART;TZID=Europe/Berlin:20260706T180000",
              "DTEND;TZID=Europe/Berlin:20260706T190000",
              "RRULE:FREQ=WEEKLY;COUNT=4"
            ]),
            vevent([
              "UID:berlin@x",
              "SUMMARY:Yoga",
              "RECURRENCE-ID;TZID=Europe/Berlin:20260713T180000",
              "DTSTART;TZID=Europe/Berlin:20260713T190000",
              "DTEND;TZID=Europe/Berlin:20260713T200000"
            ])
          ])
        )

      assert [series, _moved] = plan.events
      # 18:00 in Berlin summer time is 16:00 UTC.
      assert series.recurrence_exceptions == [~U[2026-07-13 16:00:00Z]]
    end

    test "writes an all-day series' timed exclusions as the dates they fall on" do
      plan =
        plan!(
          ics([
            vevent([
              "UID:d@x",
              "SUMMARY:Daily",
              "DTSTART;VALUE=DATE:20261005",
              "DTEND;VALUE=DATE:20261006",
              "RRULE:FREQ=DAILY;COUNT=5",
              "EXDATE:20261007T000000Z"
            ]),
            vevent([
              "UID:d@x",
              "SUMMARY:Daily, moved",
              "RECURRENCE-ID:20261008T000000Z",
              "DTSTART;VALUE=DATE:20261010",
              "DTEND;VALUE=DATE:20261011"
            ])
          ])
        )

      series = Enum.find(plan.events, &Map.has_key?(&1, :recurrence_rule))
      assert Enum.sort(series.recurrence_exceptions, Date) == [~D[2026-10-07], ~D[2026-10-08]]
      assert Properties.build_exdate(series) == "EXDATE;VALUE=DATE:20261007,20261008"
    end

    test "excludes an occurrence named in a zone only the file's VTIMEZONE defines" do
      vtimezone =
        Enum.join(
          [
            "BEGIN:VTIMEZONE",
            "TZID:Customized Time Zone",
            "BEGIN:STANDARD",
            "DTSTART:16010101T000000",
            "TZOFFSETFROM:+0200",
            "TZOFFSETTO:+0200",
            "END:STANDARD",
            "END:VTIMEZONE"
          ],
          "\r\n"
        )

      plan =
        plan!(
          ics([
            vtimezone,
            vevent([
              "UID:c@x",
              "SUMMARY:Series",
              "DTSTART;TZID=Customized Time Zone:20261102T100000",
              "DTEND;TZID=Customized Time Zone:20261102T110000",
              "RRULE:FREQ=DAILY;COUNT=3"
            ]),
            vevent([
              "UID:c@x",
              "SUMMARY:Moved",
              "RECURRENCE-ID;TZID=Customized Time Zone:20261103T100000",
              "DTSTART;TZID=Customized Time Zone:20261103T150000",
              "DTEND;TZID=Customized Time Zone:20261103T160000"
            ])
          ])
        )

      assert [series, moved] = plan.events
      assert series.recurrence_exceptions == [~U[2026-11-03 08:00:00Z]]
      assert moved.start_time == ~U[2026-11-03 13:00:00Z]
    end

    test "excludes an occurrence whose wall clock a DST change repeats, at its first instant" do
      plan =
        plan!(
          ics([
            vevent([
              "UID:dst@x",
              "SUMMARY:Night shift",
              "DTSTART;TZID=Europe/Berlin:20261024T023000",
              "DTEND;TZID=Europe/Berlin:20261024T033000",
              "RRULE:FREQ=DAILY;COUNT=3"
            ]),
            vevent([
              "UID:dst@x",
              "SUMMARY:Night shift, moved",
              "RECURRENCE-ID:20261025T023000",
              "DTSTART;TZID=Europe/Berlin:20261025T050000",
              "DTEND;TZID=Europe/Berlin:20261025T060000"
            ])
          ])
        )

      series = Enum.find(plan.events, &Map.has_key?(&1, :recurrence_rule))
      assert series.recurrence_exceptions == [~U[2026-10-25 00:30:00Z]]
    end

    test "splits a series where an override changes that occurrence and every later one" do
      plan =
        plan!(
          ics([
            timed("s@x", "Standup", "20261102T090000Z", "20261102T091500Z", [
              "RRULE:FREQ=DAILY;COUNT=5",
              "EXDATE:20261105T090000Z"
            ]),
            vevent([
              "UID:s@x",
              "SUMMARY:Standup, later",
              "RECURRENCE-ID;RANGE=THISANDFUTURE:20261104T090000Z",
              "DTSTART:20261104T140000Z",
              "DTEND:20261104T141500Z"
            ])
          ])
        )

      assert [head, tail] = plan.events
      assert head.summary == "Standup"
      assert head.recurrence_rule == "FREQ=DAILY;UNTIL=20261104T085959Z"
      refute Map.has_key?(head, :recurrence_exceptions)

      assert tail.summary == "Standup, later"
      assert tail.start_time == ~U[2026-11-04 14:00:00Z]
      assert tail.recurrence_rule == "FREQ=DAILY;COUNT=3"
      assert tail.recurrence_exceptions == [~U[2026-11-05 14:00:00Z]]
      assert plan.series == 2
    end

    test "ends a series where an override cancels that occurrence and every later one" do
      plan =
        plan!(
          ics([
            timed("s@x", "Standup", "20261102T090000Z", "20261102T091500Z", [
              "RRULE:FREQ=DAILY;COUNT=5"
            ]),
            vevent([
              "UID:s@x",
              "STATUS:CANCELLED",
              "RECURRENCE-ID;RANGE=THISANDFUTURE:20261104T090000Z",
              "DTSTART:20261104T090000Z",
              "DTEND:20261104T091500Z"
            ])
          ])
        )

      assert [%{recurrence_rule: "FREQ=DAILY;UNTIL=20261104T085959Z"}] = plan.events
    end

    test "replaces the whole series when the change starts at its first occurrence" do
      plan =
        plan!(
          ics([
            timed("s@x", "Standup", "20261102T090000Z", "20261102T091500Z", [
              "RRULE:FREQ=DAILY;COUNT=5"
            ]),
            vevent([
              "UID:s@x",
              "SUMMARY:Standup, later",
              "RECURRENCE-ID;RANGE=THISANDFUTURE:20261102T090000Z",
              "DTSTART:20261102T140000Z",
              "DTEND:20261102T141500Z"
            ])
          ])
        )

      assert [%{summary: "Standup, later", recurrence_rule: "FREQ=DAILY;COUNT=5"}] = plan.events
    end
  end
end
