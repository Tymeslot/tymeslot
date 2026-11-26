defmodule Tymeslot.CalendarGrid.IcsImport.CutoffTest do
  @moduledoc """
  Covers narrowing an `.ics` import to the events from a date on, and what a
  file with more events than one import writes is summed up as. Read through
  `IcsImport.plan/3`, the only way in.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.IcsImport
  alias Tymeslot.Test.ClockHelpers

  @from ~D[2026-06-01]

  defp ics(vevents) do
    Enum.join(
      ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//EN"] ++ vevents ++ ["END:VCALENDAR"],
      "\r\n"
    )
  end

  defp vevent(lines), do: Enum.join(["BEGIN:VEVENT"] ++ lines ++ ["END:VEVENT"], "\r\n")

  defp timed(uid, summary, start, finish, extra \\ []) do
    vevent(["UID:#{uid}", "SUMMARY:#{summary}", "DTSTART:#{start}", "DTEND:#{finish}"] ++ extra)
  end

  defp all_day(uid, summary, day, next_day) do
    vevent([
      "UID:#{uid}",
      "SUMMARY:#{summary}",
      "DTSTART;VALUE=DATE:#{day}",
      "DTEND;VALUE=DATE:#{next_day}"
    ])
  end

  defp plan_from!(vevents, timezone \\ "Etc/UTC") do
    {:ok, plan} = IcsImport.plan(ics(vevents), timezone, from: @from)
    plan
  end

  defp titles(plan), do: plan.events |> Enum.map(& &1.summary) |> Enum.sort()

  describe "plan/3 from a date" do
    test "leaves out the events that ended before it and counts them" do
      plan =
        plan_from!([
          timed("old@x", "Old", "20250310T090000Z", "20250310T100000Z"),
          timed("eve@x", "Eve", "20260531T200000Z", "20260531T210000Z"),
          timed("new@x", "New", "20260602T090000Z", "20260602T100000Z")
        ])

      assert titles(plan) == ["New"]
      assert plan.left_out == 2
      assert plan.from == @from
    end

    test "keeps an event running across midnight into the date, but not one ending as it starts" do
      plan =
        plan_from!([
          timed("late@x", "Late", "20260531T230000Z", "20260601T010000Z"),
          timed("ends@x", "Ends at midnight", "20260531T230000Z", "20260601T000000Z")
        ])

      assert titles(plan) == ["Late"]
    end

    test "starts the date at midnight in the organiser's zone" do
      # 23:30 UTC on 31 May is 00:30 on 1 June in London.
      vevents = [timed("l@x", "London morning", "20260531T233000Z", "20260531T234500Z")]

      assert titles(plan_from!(vevents, "Europe/London")) == ["London morning"]
      assert {:error, :no_events} = IcsImport.plan(ics(vevents), "Etc/UTC", from: @from)
    end

    test "keeps an all-day event on the date and drops the one the day before" do
      plan =
        plan_from!([
          all_day("before@x", "Day before", "20260531", "20260601"),
          all_day("on@x", "On the day", "20260601", "20260602")
        ])

      assert titles(plan) == ["On the day"]
    end

    test "keeps a series that started years ago and still repeats" do
      plan =
        plan_from!([
          timed("w@x", "Weekly", "20190107T090000Z", "20190107T100000Z", [
            "RRULE:FREQ=WEEKLY;BYDAY=MO"
          ])
        ])

      assert [%{summary: "Weekly", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"}] = plan.events
    end

    test "reads UNTIL as the series' end" do
      plan =
        plan_from!([
          timed("ended@x", "Ended", "20250106T090000Z", "20250106T100000Z", [
            "RRULE:FREQ=WEEKLY;UNTIL=20260525T090000Z"
          ]),
          timed("runs@x", "Runs on", "20250106T090000Z", "20250106T100000Z", [
            "RRULE:FREQ=WEEKLY;UNTIL=20260608T090000Z"
          ])
        ])

      assert titles(plan) == ["Runs on"]
      assert plan.left_out == 1
    end

    test "reads COUNT as the series' end" do
      plan =
        plan_from!([
          # Ten Mondays from 2 March 2026 end on 4 May.
          timed("ten@x", "Ten weeks", "20260302T090000Z", "20260302T100000Z", [
            "RRULE:FREQ=WEEKLY;COUNT=10"
          ]),
          # Fifteen run until 8 June.
          timed("fifteen@x", "Fifteen weeks", "20260302T090000Z", "20260302T100000Z", [
            "RRULE:FREQ=WEEKLY;COUNT=15"
          ])
        ])

      assert titles(plan) == ["Fifteen weeks"]
    end

    test "reads a long COUNT from a first start long ago as the series' end" do
      # The last of a daily series since 1900 falls on 31 May or 1 June 2026.
      until_may = Date.diff(~D[2026-05-31], ~D[1900-01-01]) + 1

      plan =
        plan_from!([
          timed("may@x", "Ends in May", "19000101T090000Z", "19000101T100000Z", [
            "RRULE:FREQ=DAILY;COUNT=#{until_may}"
          ]),
          timed("june@x", "Ends in June", "19000101T090000Z", "19000101T100000Z", [
            "RRULE:FREQ=DAILY;COUNT=#{until_may + 1}"
          ])
        ])

      assert titles(plan) == ["Ends in June"]
    end

    test "steps through a COUNT over weekdays to its end" do
      # Mondays and Wednesdays from 4 May 2026: the eighth is 27 May, the
      # ninth 1 June.
      plan =
        plan_from!([
          timed("eight@x", "Eight", "20260504T090000Z", "20260504T100000Z", [
            "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=8"
          ]),
          timed("nine@x", "Nine", "20260504T090000Z", "20260504T100000Z", [
            "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=9"
          ])
        ])

      assert titles(plan) == ["Nine"]
    end

    test "skips the months without the first start's day in a COUNT" do
      # The 31st from January 2026: the third is 31 May, the fourth 31 July.
      plan =
        plan_from!([
          timed("three@x", "Three", "20260131T090000Z", "20260131T100000Z", [
            "RRULE:FREQ=MONTHLY;COUNT=3"
          ]),
          timed("four@x", "Four", "20260131T090000Z", "20260131T100000Z", [
            "RRULE:FREQ=MONTHLY;COUNT=4"
          ])
        ])

      assert titles(plan) == ["Four"]
    end

    test "keeps a COUNT too long to step through to its end" do
      plan =
        plan_from!([
          timed("long@x", "Weekdays since 1900", "19000101T090000Z", "19000101T100000Z", [
            "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;COUNT=999999"
          ])
        ])

      assert titles(plan) == ["Weekdays since 1900"]
    end

    test "keeps an all-day series whose last occurrence is the date" do
      plan =
        plan_from!([
          vevent([
            "UID:d@x",
            "SUMMARY:Daily",
            "DTSTART;VALUE=DATE:20260525",
            "DTEND;VALUE=DATE:20260526",
            "RRULE:FREQ=DAILY;UNTIL=20260601"
          ]),
          vevent([
            "UID:e@x",
            "SUMMARY:Ended",
            "DTSTART;VALUE=DATE:20260525",
            "DTEND;VALUE=DATE:20260526",
            "RRULE:FREQ=DAILY;COUNT=7"
          ])
        ])

      assert titles(plan) == ["Daily"]
    end

    test "keeps a kept series' exclusions for the overrides it leaves out" do
      plan =
        plan_from!([
          timed("s@x", "Standup", "20260105T090000Z", "20260105T091500Z", [
            "RRULE:FREQ=WEEKLY;BYDAY=MO"
          ]),
          # Moved in March: written as an event of its own, which is past.
          vevent([
            "UID:s@x",
            "SUMMARY:Standup, moved",
            "RECURRENCE-ID:20260302T090000Z",
            "DTSTART:20260303T090000Z",
            "DTEND:20260303T091500Z"
          ]),
          # Moved in June: still to come.
          vevent([
            "UID:s@x",
            "SUMMARY:Standup, later",
            "RECURRENCE-ID:20260608T090000Z",
            "DTSTART:20260608T140000Z",
            "DTEND:20260608T141500Z"
          ])
        ])

      assert titles(plan) == ["Standup", "Standup, later"]
      series = Enum.find(plan.events, &(&1.summary == "Standup"))

      assert series.recurrence_exceptions == [~U[2026-03-02 09:00:00Z], ~U[2026-06-08 09:00:00Z]]
    end

    test "keeps the rest of a series split before the date, and drops its ended head" do
      plan =
        plan_from!([
          timed("s@x", "Standup", "20260105T090000Z", "20260105T091500Z", [
            "RRULE:FREQ=WEEKLY;BYDAY=MO"
          ]),
          vevent([
            "UID:s@x",
            "SUMMARY:Standup, later",
            "RECURRENCE-ID;RANGE=THISANDFUTURE:20260302T090000Z",
            "DTSTART:20260302T140000Z",
            "DTEND:20260302T141500Z"
          ])
        ])

      assert [%{summary: "Standup, later", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"}] =
               plan.events

      assert plan.left_out == 1
    end

    test "applies the import cap to the events kept, not to the file" do
      past =
        for n <- 0..IcsImport.max_events(),
            do: timed("p#{n}@x", "Past #{n}", "20250310T090000Z", "20250310T100000Z")

      future = timed("f@x", "Future", "20260602T090000Z", "20260602T100000Z")
      content = ics(past ++ [future])

      assert {:error, {:too_many_events, _overview}} = IcsImport.plan(content, "Etc/UTC")

      assert {:ok, %{events: [%{summary: "Future"}], left_out: left_out}} =
               IcsImport.plan(content, "Etc/UTC", from: @from)

      assert left_out == IcsImport.max_events() + 1
    end

    test "is refused when the date still keeps more events than one import writes" do
      future =
        for n <- 0..IcsImport.max_events(),
            do: timed("f#{n}@x", "F#{n}", "20260602T090000Z", "20260602T100000Z")

      assert {:error, {:too_many_events, _overview}} =
               IcsImport.plan(ics(future), "Etc/UTC", from: @from)
    end
  end

  describe "a file with more events than one import writes" do
    setup do
      ClockHelpers.freeze_clock(~U[2026-11-23 12:00:00Z])
      :ok
    end

    test "sums up what it holds and what each suggested date keeps" do
      # The 15th of every month from January 2025 to November 2026, 990
      # events on 15 November 2026, and a weekly series since 2024.
      monthly =
        for month <- 0..22 do
          day = ~D[2025-01-15] |> Date.shift(month: month) |> Date.to_iso8601(:basic)
          timed("m#{month}@x", "Month #{month}", "#{day}T090000Z", "#{day}T100000Z")
        end

      recent =
        for n <- 1..990,
            do: timed("r#{n}@x", "Recent #{n}", "20261115T090000Z", "20261115T100000Z")

      weekly =
        timed("w@x", "Weekly", "20240101T090000Z", "20240101T100000Z", [
          "RRULE:FREQ=WEEKLY;BYDAY=MO"
        ])

      assert {:error, {:too_many_events, overview}} =
               IcsImport.plan(ics(monthly ++ recent ++ [weekly]), "Europe/London")

      assert overview.events == 23 + 990 + 1
      assert overview.series == 1
      assert overview.first == ~D[2024-01-01]
      assert overview.last == ~D[2026-11-15]

      # The series runs on past every date; the 15ths from December 2025,
      # June and September 2026 are kept by the first three, as are the 990.
      assert overview.suggestions == [
               %{from: ~D[2025-11-23], events: 12 + 990 + 1, importable: false},
               %{from: ~D[2026-05-23], events: 6 + 990 + 1, importable: true},
               %{from: ~D[2026-08-23], events: 3 + 990 + 1, importable: true},
               %{from: ~D[2026-11-23], events: 1, importable: true}
             ]
    end

    # Each of these series runs on for centuries yet; stepping every
    # occurrence since 1900, once per suggested date, takes minutes. Most
    # are worked out directly; a few BYDAY ones are stepped for two years,
    # as `RecurrenceExpander.last_start/2`'s own tests cover in full.
    @tag timeout: 20_000
    test "judges a COUNT series from long ago without stepping through it" do
      series =
        for n <- 1..(IcsImport.max_events() + 1) do
          rule =
            if n > 10,
              do: "RRULE:FREQ=DAILY;COUNT=999999",
              else: "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;COUNT=999999"

          timed("s#{n}@x", "S#{n}", "19000101T090000Z", "19000101T100000Z", [rule])
        end

      assert {:error, {:too_many_events, overview}} = IcsImport.plan(ics(series), "Etc/UTC")

      assert Enum.map(overview.suggestions, & &1.events) ==
               List.duplicate(IcsImport.max_events() + 1, 4)
    end

    test "is refused unread past the most events a file may hold" do
      events =
        for n <- 0..IcsImport.max_file_events(),
            do: timed("e#{n}@x", "E", "20261105T090000Z", "20261105T100000Z")

      assert IcsImport.plan(ics(events), "Etc/UTC") == {:error, :too_many_events}
    end
  end
end
