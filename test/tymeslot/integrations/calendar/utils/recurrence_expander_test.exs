defmodule Tymeslot.Integrations.Calendar.RecurrenceExpanderTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  describe "parse_rrule/1" do
    test "parses FREQ and INTERVAL" do
      assert {:ok, %{freq: :weekly, interval: 1}} =
               RecurrenceExpander.parse_rrule("FREQ=WEEKLY;INTERVAL=1")
    end

    test "defaults INTERVAL to 1 when omitted" do
      assert {:ok, %{freq: :daily, interval: 1}} =
               RecurrenceExpander.parse_rrule("FREQ=DAILY")
    end

    test "parses UNTIL as DateTime" do
      assert {:ok, %{freq: :weekly, until: %DateTime{}}} =
               RecurrenceExpander.parse_rrule("FREQ=WEEKLY;UNTIL=20261231T235959Z")
    end

    test "parses COUNT" do
      assert {:ok, %{freq: :weekly, count: 10}} =
               RecurrenceExpander.parse_rrule("FREQ=WEEKLY;COUNT=10")
    end

    test "parses BYDAY" do
      assert {:ok, %{freq: :weekly, by_day: [:monday, :wednesday, :friday]}} =
               RecurrenceExpander.parse_rrule("FREQ=WEEKLY;BYDAY=MO,WE,FR")
    end

    test "returns error for nil" do
      assert :error = RecurrenceExpander.parse_rrule(nil)
    end

    test "returns error for empty string" do
      assert :error = RecurrenceExpander.parse_rrule("")
    end

    test "parses UNTIL without trailing Z as UTC" do
      assert {:ok, %{until: %DateTime{} = until}} =
               RecurrenceExpander.parse_rrule("FREQ=WEEKLY;UNTIL=20260411T000000")

      assert until == ~U[2026-04-11 00:00:00Z]
    end

    test "parses DATE-form UNTIL (all-day series) as end-of-day UTC" do
      # RFC 5545 §3.3.10: all-day recurrences carry a bare-date UNTIL. It must
      # still parse (as inclusive end-of-day) — a nil here would treat the
      # series as unbounded.
      assert {:ok, %{until: %DateTime{} = until}} =
               RecurrenceExpander.parse_rrule("FREQ=DAILY;UNTIL=20260411")

      assert until == ~U[2026-04-11 23:59:59Z]
    end
  end

  describe "expand/4 with weekly recurrence" do
    test "expands weekly event into occurrences within range" do
      event = %{
        uid: "weekly-1",
        summary: "Standup",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1",
        transparency: "opaque"
      }

      range_start = ~U[2026-04-10 00:00:00Z]
      range_end = ~U[2026-04-16 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert length(occurrences) == 1
      [occ] = occurrences
      assert occ.start_time == ~U[2026-04-10 09:00:00Z]
      assert occ.end_time == ~U[2026-04-10 10:00:00Z]
      assert occ.summary == "Standup"
      assert occ.transparency == "opaque"
      assert occ.uid == "weekly-1"
    end

    test "expands multiple weeks within range" do
      event = %{
        uid: "weekly-2",
        summary: "Meeting",
        start_time: ~U[2026-04-03 14:00:00Z],
        end_time: ~U[2026-04-03 15:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      expected_starts =
        Enum.map([3, 10, 17, 24], fn day ->
          DateTime.new!(Date.add(~D[2026-04-01], day - 1), ~T[14:00:00], "Etc/UTC")
        end)

      assert Enum.map(occurrences, & &1.start_time) == expected_starts
    end

    test "respects INTERVAL=2 for biweekly" do
      event = %{
        uid: "biweekly-1",
        summary: "Biweekly",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=2"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      starts = Enum.map(occurrences, & &1.start_time)
      assert ~U[2026-04-03 09:00:00Z] in starts
      assert ~U[2026-04-17 09:00:00Z] in starts
      refute ~U[2026-04-10 09:00:00Z] in starts
    end

    test "includes original occurrence when it falls within range" do
      event = %{
        uid: "orig-1",
        summary: "First",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-05 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      assert [%{start_time: ~U[2026-04-03 09:00:00Z]}] = occurrences
    end

    test "returns empty list when no occurrences fall in range" do
      event = %{
        uid: "none-1",
        summary: "Past",
        start_time: ~U[2026-01-03 09:00:00Z],
        end_time: ~U[2026-01-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;COUNT=2"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      assert [] = RecurrenceExpander.expand(event, range_start, range_end)
    end

    test "respects UNTIL boundary" do
      event = %{
        uid: "until-1",
        summary: "Limited",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;UNTIL=20260411T000000Z"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~U[2026-04-03 09:00:00Z] in starts
      assert ~U[2026-04-10 09:00:00Z] in starts
      refute ~U[2026-04-17 09:00:00Z] in starts
    end

    test "respects COUNT boundary" do
      event = %{
        uid: "count-1",
        summary: "Counted",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;COUNT=3"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      assert length(occurrences) == 3
    end
  end

  describe "expand/4 with non-recurring events" do
    test "returns event as-is when no recurrence_rule" do
      event = %{
        uid: "single-1",
        summary: "One-off",
        start_time: ~U[2026-04-10 09:00:00Z],
        end_time: ~U[2026-04-10 10:00:00Z],
        recurrence_rule: nil
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      assert [^event] = RecurrenceExpander.expand(event, range_start, range_end)
    end
  end

  describe "expand/4 with daily recurrence" do
    test "expands daily event" do
      event = %{
        uid: "daily-1",
        summary: "Daily",
        start_time: ~U[2026-04-01 08:00:00Z],
        end_time: ~U[2026-04-01 08:30:00Z],
        recurrence_rule: "FREQ=DAILY;INTERVAL=1"
      }

      range_start = ~U[2026-04-03 00:00:00Z]
      range_end = ~U[2026-04-05 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~U[2026-04-03 08:00:00Z] in starts
      assert ~U[2026-04-04 08:00:00Z] in starts
      assert ~U[2026-04-05 08:00:00Z] in starts
      assert length(occurrences) == 3
    end

    test "respects daily INTERVAL=3" do
      event = %{
        uid: "daily-3",
        summary: "Every 3 days",
        start_time: ~U[2026-04-01 08:00:00Z],
        end_time: ~U[2026-04-01 08:30:00Z],
        recurrence_rule: "FREQ=DAILY;INTERVAL=3"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-10 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~U[2026-04-01 08:00:00Z] in starts
      assert ~U[2026-04-04 08:00:00Z] in starts
      assert ~U[2026-04-07 08:00:00Z] in starts
      assert ~U[2026-04-10 08:00:00Z] in starts
      assert length(occurrences) == 4
    end
  end

  describe "expand/4 with monthly recurrence" do
    test "expands monthly event" do
      event = %{
        uid: "monthly-1",
        summary: "Monthly",
        start_time: ~U[2026-01-15 10:00:00Z],
        end_time: ~U[2026-01-15 11:00:00Z],
        recurrence_rule: "FREQ=MONTHLY;INTERVAL=1"
      }

      range_start = ~U[2026-03-01 00:00:00Z]
      range_end = ~U[2026-05-31 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~U[2026-03-15 10:00:00Z] in starts
      assert ~U[2026-04-15 10:00:00Z] in starts
      assert ~U[2026-05-15 10:00:00Z] in starts
      assert length(occurrences) == 3
    end

    test "clamps day to end of short month" do
      event = %{
        uid: "monthly-31",
        summary: "End of month",
        start_time: ~U[2026-01-31 10:00:00Z],
        end_time: ~U[2026-01-31 11:00:00Z],
        recurrence_rule: "FREQ=MONTHLY;INTERVAL=1"
      }

      range_start = ~U[2026-02-01 00:00:00Z]
      range_end = ~U[2026-02-28 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert [%{start_time: ~U[2026-02-28 10:00:00Z]}] = occurrences
    end
  end

  describe "expand/4 with yearly recurrence" do
    test "expands yearly event" do
      event = %{
        uid: "yearly-1",
        summary: "Anniversary",
        start_time: ~U[2024-06-15 09:00:00Z],
        end_time: ~U[2024-06-15 10:00:00Z],
        recurrence_rule: "FREQ=YEARLY;INTERVAL=1"
      }

      range_start = ~U[2026-06-01 00:00:00Z]
      range_end = ~U[2026-06-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert [%{start_time: ~U[2026-06-15 09:00:00Z]}] = occurrences
    end
  end

  describe "expand/4 with BYDAY" do
    test "weekly with specific days" do
      event = %{
        uid: "byday-1",
        summary: "MWF Meeting",
        start_time: ~U[2026-04-06 09:00:00Z],
        end_time: ~U[2026-04-06 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE,FR"
      }

      # April 6 2026 is a Monday
      range_start = ~U[2026-04-06 00:00:00Z]
      range_end = ~U[2026-04-12 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      starts = Enum.map(occurrences, & &1.start_time)

      # Mon Apr 6, Wed Apr 8, Fri Apr 10
      assert ~U[2026-04-06 09:00:00Z] in starts
      assert ~U[2026-04-08 09:00:00Z] in starts
      assert ~U[2026-04-10 09:00:00Z] in starts
      assert length(occurrences) == 3
    end
  end

  describe "expand/4 preserves event fields" do
    test "copies all original fields to each occurrence" do
      event = %{
        uid: "preserve-1",
        summary: "Full Event",
        description: "With all fields",
        location: "Room 42",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1",
        transparency: "opaque",
        href: "/cal/event.ics",
        etag: "abc123"
      }

      range_start = ~U[2026-04-10 00:00:00Z]
      range_end = ~U[2026-04-10 23:59:59Z]

      [occ] = RecurrenceExpander.expand(event, range_start, range_end)

      assert occ.uid == "preserve-1"
      assert occ.summary == "Full Event"
      assert occ.description == "With all fields"
      assert occ.location == "Room 42"
      assert occ.transparency == "opaque"
      assert occ.href == "/cal/event.ics"
    end
  end
end
