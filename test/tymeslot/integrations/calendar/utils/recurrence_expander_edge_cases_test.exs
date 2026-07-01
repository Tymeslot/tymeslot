defmodule Tymeslot.Integrations.Calendar.RecurrenceExpanderEdgeCasesTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

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
end
