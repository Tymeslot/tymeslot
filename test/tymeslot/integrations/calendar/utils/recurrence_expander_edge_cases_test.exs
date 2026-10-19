defmodule Tymeslot.Integrations.Calendar.RecurrenceExpanderEdgeCasesTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Test.LogCapture

  describe "expand/4 with EXDATE exclusions" do
    test "excludes specific dates" do
      event = %{
        uid: "exdate-1",
        summary: "Weekly",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      exdates = [~U[2026-04-10 09:00:00Z], ~U[2026-04-24 09:00:00Z]]
      occurrences = RecurrenceExpander.expand(event, range_start, range_end, exdates: exdates)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~U[2026-04-03 09:00:00Z] in starts
      assert ~U[2026-04-17 09:00:00Z] in starts
      refute ~U[2026-04-10 09:00:00Z] in starts
      refute ~U[2026-04-24 09:00:00Z] in starts
    end

    test "excludes Date-valued EXDATEs from all-day recurring events" do
      event = %{
        uid: "exdate-allday-1",
        summary: "All-day weekly",
        start_time: ~D[2026-04-03],
        end_time: ~D[2026-04-04],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      exdates = [~D[2026-04-10], ~D[2026-04-24]]
      occurrences = RecurrenceExpander.expand(event, range_start, range_end, exdates: exdates)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~D[2026-04-03] in starts
      assert ~D[2026-04-17] in starts
      refute ~D[2026-04-10] in starts
      refute ~D[2026-04-24] in starts
    end
  end

  describe "expand/4 with all-day events (Date structs)" do
    test "expands weekly all-day event" do
      event = %{
        uid: "allday-weekly-1",
        summary: "Team Lunch",
        start_time: ~D[2026-04-03],
        end_time: ~D[2026-04-04],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~D[2026-04-03] in starts
      assert ~D[2026-04-10] in starts
      assert ~D[2026-04-17] in starts
      assert ~D[2026-04-24] in starts
      assert length(occurrences) == 4
    end

    test "preserves Date structs in expanded occurrences" do
      event = %{
        uid: "allday-daily-1",
        summary: "Daily Reminder",
        start_time: ~D[2026-04-01],
        end_time: ~D[2026-04-02],
        recurrence_rule: "FREQ=DAILY;COUNT=3"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert [
               %{start_time: ~D[2026-04-01], end_time: ~D[2026-04-02]},
               %{start_time: ~D[2026-04-02], end_time: ~D[2026-04-03]},
               %{start_time: ~D[2026-04-03], end_time: ~D[2026-04-04]}
             ] = occurrences
    end

    test "expands multi-day all-day event preserving duration" do
      event = %{
        uid: "allday-multi-1",
        summary: "Conference",
        start_time: ~D[2026-04-06],
        end_time: ~D[2026-04-08],
        recurrence_rule: "FREQ=MONTHLY;INTERVAL=1;COUNT=2"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-06-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert [
               %{start_time: ~D[2026-04-06], end_time: ~D[2026-04-08]},
               %{start_time: ~D[2026-05-06], end_time: ~D[2026-05-08]}
             ] = occurrences
    end

    test "handles range_start and range_end as Date structs" do
      event = %{
        uid: "allday-range-1",
        summary: "All-day",
        start_time: ~D[2026-04-03],
        end_time: ~D[2026-04-04],
        recurrence_rule: "FREQ=WEEKLY;COUNT=3"
      }

      range_start = ~D[2026-04-01]
      range_end = ~D[2026-04-30]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert length(occurrences) == 3
    end
  end

  describe "expand/4 boundary edges" do
    # These cases pin behaviour at the awkward corners of RRULE expansion
    # where a naive loop could either produce phantom occurrences or
    # silently skip the master event. `COUNT=0` is legal per RFC 5545
    # (though rarely seen in the wild) and must collapse to the empty
    # list; `UNTIL < DTSTART` is a nonsense rule that some CalDAV clients
    # still emit during bulk-edit flows and must likewise collapse
    # without falling through to the fail-open "return master" arm.

    test "COUNT=0 produces an empty expansion, not a single fail-open occurrence" do
      event = %{
        uid: "count-zero",
        summary: "Nothing",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;COUNT=0"
      }

      occurrences =
        RecurrenceExpander.expand(event, ~U[2026-04-01 00:00:00Z], ~U[2026-05-31 23:59:59Z])

      assert occurrences == []
    end

    test "UNTIL strictly before DTSTART produces an empty expansion" do
      event = %{
        uid: "until-before-start",
        summary: "Already expired",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;UNTIL=20260101T000000Z"
      }

      occurrences =
        RecurrenceExpander.expand(event, ~U[2026-04-01 00:00:00Z], ~U[2026-05-31 23:59:59Z])

      assert occurrences == []
    end

    test "all-day series honours a DATE-form UNTIL instead of running unbounded" do
      # The recurrence editor emits a bare-date UNTIL for all-day events. If the
      # expander can't parse it, the series is treated as endless and paints
      # occurrences past its intended end (capped only by @max_occurrences).
      event = %{
        uid: "allday-until",
        summary: "All-day standup",
        start_time: ~D[2026-04-01],
        end_time: ~D[2026-04-02],
        recurrence_rule: "FREQ=DAILY;UNTIL=20260405"
      }

      occurrences =
        RecurrenceExpander.expand(event, ~U[2026-04-01 00:00:00Z], ~U[2026-04-30 23:59:59Z])

      starts = Enum.map(occurrences, & &1.start_time)

      # Inclusive through the UNTIL date, nothing after it.
      assert starts == [
               ~D[2026-04-01],
               ~D[2026-04-02],
               ~D[2026-04-03],
               ~D[2026-04-04],
               ~D[2026-04-05]
             ]
    end
  end

  describe "expand/4 across daylight-saving transitions" do
    # A recurring event must keep its *local wall-clock* time across a DST
    # change. "Every Monday at 15:00 Berlin" stays 15:00 even after the clocks
    # change — the absolute UTC instant is what shifts by an hour, not the time
    # the user sees. The regression these pin: stepping with DateTime.add/3
    # (instant arithmetic) holds the UTC instant fixed and silently drifts the
    # local time, so a 15:00 series would show as 14:00 after the autumn change.

    test "weekly series keeps its local time across the autumn fall-back" do
      # Europe/Berlin falls back from CEST (+02:00) to CET (+01:00) on
      # 2026-10-25. The series is anchored two weeks before, in summer time.
      anchor = DateTime.new!(~D[2026-10-12], ~T[15:00:00], "Europe/Berlin")

      event = %{
        uid: "dst-weekly",
        summary: "Weekly sync",
        start_time: anchor,
        end_time: DateTime.new!(~D[2026-10-12], ~T[16:00:00], "Europe/Berlin"),
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      occurrences =
        RecurrenceExpander.expand(
          event,
          ~U[2026-10-01 00:00:00Z],
          ~U[2026-11-15 23:59:59Z]
        )

      # Every occurrence reads 15:00 local, on both sides of the transition.
      assert Enum.all?(occurrences, &(DateTime.to_time(&1.start_time) == ~T[15:00:00]))

      utc_by_date =
        Map.new(occurrences, fn occ ->
          {DateTime.to_date(occ.start_time), DateTime.shift_zone!(occ.start_time, "Etc/UTC")}
        end)

      # Before the change: 15:00 CEST == 13:00 UTC.
      assert utc_by_date[~D[2026-10-19]] == ~U[2026-10-19 13:00:00Z]
      # After the change: 15:00 CET == 14:00 UTC (the instant moved, not the clock).
      assert utc_by_date[~D[2026-10-26]] == ~U[2026-10-26 14:00:00Z]
      assert utc_by_date[~D[2026-11-02]] == ~U[2026-11-02 14:00:00Z]
    end

    test "weekly BYDAY series keeps its local time across the autumn fall-back" do
      # The single-weekday BYDAY shape (what the recurrence editor emits by
      # default) steps through advance_to_next_byday/3's week-wrap branch on
      # every iteration — since BYDAY=MO never has a later weekday in the same
      # week. That branch must stay in the event's own timezone, exactly like
      # the plain-weekly path above, or a 15:00 Monday series drifts to 14:00
      # after Berlin's 2026-10-25 fall-back.
      anchor = DateTime.new!(~D[2026-10-12], ~T[15:00:00], "Europe/Berlin")

      event = %{
        uid: "dst-weekly-byday",
        summary: "Monday standup",
        start_time: anchor,
        end_time: DateTime.new!(~D[2026-10-12], ~T[15:30:00], "Europe/Berlin"),
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
      }

      occurrences =
        RecurrenceExpander.expand(
          event,
          ~U[2026-10-01 00:00:00Z],
          ~U[2026-11-15 23:59:59Z]
        )

      assert Enum.all?(occurrences, &(DateTime.to_time(&1.start_time) == ~T[15:00:00]))

      utc_by_date =
        Map.new(occurrences, fn occ ->
          {DateTime.to_date(occ.start_time), DateTime.shift_zone!(occ.start_time, "Etc/UTC")}
        end)

      # All Mondays, so the fall-back must land the instant an hour later in UTC
      # while the wall clock stays at 15:00.
      assert utc_by_date[~D[2026-10-19]] == ~U[2026-10-19 13:00:00Z]
      assert utc_by_date[~D[2026-10-26]] == ~U[2026-10-26 14:00:00Z]
      assert utc_by_date[~D[2026-11-02]] == ~U[2026-11-02 14:00:00Z]
    end

    test "monthly series keeps its local time across a DST transition" do
      anchor = DateTime.new!(~D[2026-09-15], ~T[09:30:00], "Europe/Berlin")

      event = %{
        uid: "dst-monthly",
        summary: "Monthly review",
        start_time: anchor,
        end_time: DateTime.new!(~D[2026-09-15], ~T[10:30:00], "Europe/Berlin"),
        recurrence_rule: "FREQ=MONTHLY;INTERVAL=1"
      }

      occurrences =
        RecurrenceExpander.expand(
          event,
          ~U[2026-09-01 00:00:00Z],
          ~U[2026-11-30 23:59:59Z]
        )

      assert Enum.all?(occurrences, &(DateTime.to_time(&1.start_time) == ~T[09:30:00]))

      utc_by_date =
        Map.new(occurrences, fn occ ->
          {DateTime.to_date(occ.start_time), DateTime.shift_zone!(occ.start_time, "Etc/UTC")}
        end)

      # September (CEST): 09:30 == 07:30 UTC. November (CET): 09:30 == 08:30 UTC.
      assert utc_by_date[~D[2026-09-15]] == ~U[2026-09-15 07:30:00Z]
      assert utc_by_date[~D[2026-11-15]] == ~U[2026-11-15 08:30:00Z]
    end
  end

  describe "expand/4 for a series whose time falls in a spring-forward gap" do
    # Europe/Berlin skips 02:00 to 03:00 on 2026-03-29, so a daily 02:30
    # series has no 02:30 that day. Every occurrence must take its wall clock
    # from the first start, never from the occurrence before it: otherwise
    # the gap day's 03:00 carries forward, and the same occurrence starts at
    # another time depending on whether the range reached back past the gap.
    # The start is what an occurrence's uid is built from, so a moving start
    # also churns the stored occurrence and breaks RECURRENCE-ID matching.

    setup do
      first = DateTime.new!(~D[2026-03-20], ~T[02:30:00], "Europe/Berlin")

      event = %{
        uid: "gap-daily",
        summary: "Early sync",
        start_time: first,
        end_time: DateTime.add(first, 30, :minute),
        recurrence_rule: "FREQ=DAILY"
      }

      %{event: event}
    end

    defp start_on(occurrences, date),
      do:
        Enum.find_value(occurrences, &(DateTime.to_date(&1.start_time) == date && &1.start_time))

    test "an occurrence after the gap starts the same whatever the range", %{event: event} do
      across_gap =
        RecurrenceExpander.expand(event, ~U[2026-03-25 00:00:00Z], ~U[2026-04-10 00:00:00Z])

      after_gap =
        RecurrenceExpander.expand(event, ~U[2026-04-07 00:00:00Z], ~U[2026-04-10 00:00:00Z])

      expected = DateTime.new!(~D[2026-04-08], ~T[02:30:00], "Europe/Berlin")
      assert start_on(across_gap, ~D[2026-04-08]) == expected
      assert start_on(after_gap, ~D[2026-04-08]) == expected
    end

    test "the gap day itself resolves to the same instant in every range", %{event: event} do
      starts =
        for range_start <- [
              ~U[2026-03-20 00:00:00Z],
              ~U[2026-03-28 12:00:00Z],
              ~U[2026-03-29 00:00:00Z]
            ] do
          event
          |> RecurrenceExpander.expand(range_start, ~U[2026-03-31 00:00:00Z])
          |> start_on(~D[2026-03-29])
        end

      # 02:30 does not exist that day; it resolves forward to 03:00 CEST.
      gap_start = DateTime.new!(~D[2026-03-29], ~T[03:00:00], "Europe/Berlin")
      assert starts == [gap_start, gap_start, gap_start]
    end

    test "a monthly and a yearly series keep their time after a gap month", %{event: event} do
      first = DateTime.new!(~D[2025-03-29], ~T[02:30:00], "Europe/Berlin")

      for rule <- ["FREQ=MONTHLY", "FREQ=YEARLY"] do
        series = %{
          event
          | start_time: first,
            end_time: DateTime.add(first, 30, :minute),
            recurrence_rule: rule
        }

        occurrences =
          RecurrenceExpander.expand(series, ~U[2025-01-01 00:00:00Z], ~U[2027-12-31 00:00:00Z])

        assert DateTime.to_time(start_on(occurrences, ~D[2026-03-29])) == ~T[03:00:00]
        assert DateTime.to_time(start_on(occurrences, ~D[2027-03-29])) == ~T[02:30:00]
      end
    end
  end

  describe "expand/4 for a series whose time falls in an autumn overlap" do
    # Europe/Berlin turns 03:00 CEST back to 02:00 CET on 2026-10-25, so
    # 02:30 happens twice that day. The overlap day takes the first (CEST)
    # 02:30, and the day after is 02:30 CET, whichever range is expanded.
    setup do
      first = DateTime.new!(~D[2026-10-20], ~T[02:30:00], "Europe/Berlin")

      event = %{
        uid: "overlap-daily",
        summary: "Early sync",
        start_time: first,
        end_time: DateTime.add(first, 30, :minute),
        recurrence_rule: "FREQ=DAILY"
      }

      %{event: event}
    end

    test "the overlap day and the day after start the same in every range", %{event: event} do
      starts =
        for range_start <- [
              ~U[2026-10-20 00:00:00Z],
              ~U[2026-10-24 12:00:00Z],
              ~U[2026-10-25 00:00:00Z]
            ] do
          occurrences = RecurrenceExpander.expand(event, range_start, ~U[2026-10-28 00:00:00Z])
          {start_on(occurrences, ~D[2026-10-25]), start_on(occurrences, ~D[2026-10-26])}
        end

      # 00:30Z is 02:30 CEST, the first of the two; 01:30Z is 02:30 CET.
      expected = {~U[2026-10-25 00:30:00Z], ~U[2026-10-26 01:30:00Z]}

      utc = fn {a, b} ->
        {DateTime.shift_zone!(a, "Etc/UTC"), DateTime.shift_zone!(b, "Etc/UTC")}
      end

      assert Enum.map(starts, utc) == [expected, expected, expected]
      assert {%{zone_abbr: "CEST"}, %{zone_abbr: "CET"}} = hd(starts)
    end

    test "the day after starts at 02:30 CET from a range after the change", %{event: event} do
      occurrences =
        RecurrenceExpander.expand(event, ~U[2026-10-25 02:00:00Z], ~U[2026-10-28 00:00:00Z])

      assert start_on(occurrences, ~D[2026-10-26]) ==
               DateTime.new!(~D[2026-10-26], ~T[02:30:00], "Europe/Berlin")
    end
  end

  describe "expand/4 for a series that started long before the range" do
    # The safety cap bounds the occurrences a range gets, not the steps taken
    # from the series' first start: a standing meeting that has run for years
    # must still block this week's slots.

    @week_start ~U[2026-10-05 00:00:00Z]
    @week_end ~U[2026-10-11 23:59:59Z]

    defp berlin(date, time), do: DateTime.new!(date, time, "Europe/Berlin")

    defp old_series(rule, first_day) do
      %{
        uid: "old-series",
        summary: "Standing meeting",
        start_time: berlin(first_day, ~T[09:00:00]),
        end_time: berlin(first_day, ~T[09:30:00]),
        recurrence_rule: rule
      }
    end

    defp dates(occurrences), do: Enum.map(occurrences, &DateTime.to_date(&1.start_time))

    test "a daily series from three years ago occurs every day this week, at its own time" do
      occurrences =
        "FREQ=DAILY"
        |> old_series(~D[2023-10-02])
        |> RecurrenceExpander.expand(@week_start, @week_end)

      assert dates(occurrences) == Enum.to_list(Date.range(~D[2026-10-05], ~D[2026-10-11]))
      # Three years of DST changes later, the wall clock still reads 09:00.
      assert Enum.reject(occurrences, &(DateTime.to_time(&1.start_time) == ~T[09:00:00])) == []
    end

    test "a weekday series from three years ago occurs Monday to Friday this week" do
      occurrences =
        "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        |> old_series(~D[2023-10-02])
        |> RecurrenceExpander.expand(@week_start, @week_end)

      assert dates(occurrences) == Enum.to_list(Date.range(~D[2026-10-05], ~D[2026-10-09]))
    end

    test "a fortnightly series from three years ago keeps to its own weeks" do
      # 2023-10-02 to 2026-09-28 is 156 weeks, so of the three weeks from
      # 21 September the series is on only in the week of 28 September. The
      # range is chosen so that a skip by an odd number of weeks would land
      # in the off weeks.
      occurrences =
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH"
        |> old_series(~D[2023-10-03])
        |> RecurrenceExpander.expand(~U[2026-09-21 00:00:00Z], @week_end)

      assert dates(occurrences) == [~D[2026-09-29], ~D[2026-10-01]]
    end

    test "a series whose COUNT ran out years ago has no occurrences this week" do
      occurrences =
        "FREQ=DAILY;COUNT=10"
        |> old_series(~D[2023-10-02])
        |> RecurrenceExpander.expand(@week_start, @week_end)

      assert occurrences == []
    end

    test "the cap bounds the occurrences inside the range, counted from its start" do
      occurrences =
        "FREQ=DAILY"
        |> old_series(~D[2023-10-02])
        |> RecurrenceExpander.expand(~U[2026-01-01 00:00:00Z], ~U[2030-12-31 23:59:59Z])

      assert length(occurrences) == 500
      assert hd(dates(occurrences)) == ~D[2026-01-01]
    end

    test "a rule that never moves forward is unreadable, so its event shows once" do
      # INTERVAL=0 (or below) would step on the same period for ever. RFC 5545
      # requires a positive INTERVAL, so the rule is refused like any other
      # invalid rule and the event is returned as it is.
      for rule <- ["FREQ=DAILY;INTERVAL=0", "FREQ=WEEKLY;INTERVAL=-1;BYDAY=MO,WE"] do
        event = old_series(rule, ~D[2023-10-02])

        assert RRule.parse(rule) == :error
        assert RecurrenceExpander.expand(event, @week_start, @week_end) == [event]
        assert RecurrenceExpander.count_before(rule, event.start_time, @week_start) == 1
      end
    end

    test "a feed full of rules that never move forward shows each event once" do
      # Each such rule once spent the whole step budget (about a quarter of a
      # second) before giving up, so a hostile feed stalled availability.
      # Read as unreadable, each is now shown once, as it is, without stepping.
      events =
        for n <- 1..200,
            do: old_series("FREQ=DAILY;INTERVAL=0;COUNT=#{n + 1_000_000}", ~D[1900-01-01])

      expanded = Enum.flat_map(events, &RecurrenceExpander.expand(&1, @week_start, @week_end))

      assert expanded == events
    end

    test "a series that runs out of step budget before the range says so" do
      # COUNT stops the series being moved forward to the range, so its
      # periods are stepped one by one from 1700; the budget runs out in the
      # 1970s, and the series' later occurrences are then missing.
      LogCapture.attach(level: :warning)

      occurrences =
        "FREQ=DAILY;COUNT=987654321"
        |> old_series(~D[1700-01-01])
        |> RecurrenceExpander.expand(@week_start, @week_end)

      assert occurrences == []

      %{level: :warning, meta: meta} =
        LogCapture.await_log("Recurrence expansion stopped after 100000 periods")

      assert %{freq: :daily, count: 987_654_321} = meta
    end

    test "the live busy-time check sees this week's occurrence of a years-old series" do
      raw = %{
        uid: "old-standup",
        summary: "Standup",
        timezone: "Europe/Berlin",
        dtstart: DateTime.shift_zone!(berlin(~D[2023-10-02], ~T[09:00:00]), "Etc/UTC"),
        dtend: DateTime.shift_zone!(berlin(~D[2023-10-02], ~T[09:30:00]), "Etc/UTC"),
        rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
      }

      starts =
        [raw]
        |> ICalNormaliser.expand_occurrences(@week_start, @week_end)
        |> Enum.map(& &1.start_time)

      # 09:00 CEST is 07:00 UTC.
      assert ~U[2026-10-07 07:00:00Z] in starts
      assert length(starts) == 5
    end
  end

  describe "a CalDAV series whose UNTIL is a floating wall clock" do
    # An Auckland (UTC+12) daily series at 07:30 whose UNTIL is midnight at
    # the start of 15 April, written without a zone: read in the series' zone
    # its last occurrence is 14 April. Read in UTC the bound would be noon on
    # 15 April in Auckland, and 15 April's 07:30 would be offered as busy too.
    test "ends on the series' own last day, through the parser and the normaliser" do
      {:ok, raw_events} =
        ICalParser.parse("""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Test//EN
        BEGIN:VEVENT
        UID:auckland-daily
        DTSTART;TZID=Pacific/Auckland:20260410T073000
        DTEND;TZID=Pacific/Auckland:20260410T080000
        RRULE:FREQ=DAILY;UNTIL=20260415T000000
        SUMMARY:Daily check-in
        END:VEVENT
        END:VCALENDAR
        """)

      last =
        raw_events
        |> ICalNormaliser.expand_occurrences(~U[2026-04-01 00:00:00Z], ~U[2026-04-30 00:00:00Z])
        |> Enum.map(& &1.start_time)
        |> Enum.max(DateTime)

      assert DateTime.to_naive(DateTime.shift_zone!(last, "Pacific/Auckland")) ==
               ~N[2026-04-14 07:30:00]
    end
  end
end
