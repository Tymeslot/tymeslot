defmodule Tymeslot.CalendarGrid.EventVideoRoomTimesTest do
  @moduledoc """
  When a calendar grid event's video room opens its lobby and stops being
  needed. Every bound here must err late: a room deleted before its event is
  over leaves attendees with a dead join link.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :video
  @moduletag :unit

  alias Tymeslot.CalendarGrid.EventVideoRoomTimes

  describe "for_event/1, one-off events" do
    test "a timed event's lobby opens at its start and its room is needed until it ends" do
      assert EventVideoRoomTimes.for_event(timed(nil)) ==
               {:exact, ~U[2026-10-05 09:00:00Z], ~U[2026-10-05 10:00:00Z]}
    end

    # The first day begins 14 hours before midnight UTC somewhere, and the
    # exclusive end date is midnight in some zone up to a day after UTC's.
    test "an all-day event opens its lobby as its first day begins anywhere and keeps a day's margin" do
      event = %{all_day: true, start_date: ~D[2026-10-05], end_date: ~D[2026-10-06]}

      assert EventVideoRoomTimes.for_event(event) ==
               {:exact, ~U[2026-10-04 10:00:00Z], ~U[2026-10-07 00:00:00Z]}
    end

    test "the create form's payload is read like a cached row" do
      payload = %{
        all_day: false,
        start: ~U[2026-10-05 09:00:00.123456Z],
        end: ~U[2026-10-05 10:00:00Z],
        recurrence_rule: nil
      }

      assert EventVideoRoomTimes.for_event(payload) ==
               {:exact, ~U[2026-10-05 09:00:00Z], ~U[2026-10-05 10:00:00Z]}
    end
  end

  describe "for_event/1, recurring series" do
    test "a series ending on a date is needed until a day after its last possible occurrence" do
      assert {:series, _lobby, ~U[2026-11-02 00:59:59Z]} =
               EventVideoRoomTimes.for_event(timed("FREQ=DAILY;UNTIL=20261031T235959Z"))
    end

    # Three repetitions of a weekly rule, each allowed a week plus a week for
    # its weekday filter: 42 days after the first start, then the event's hour
    # and a day's margin. The real last occurrence (Monday 12 October) ends
    # well inside that.
    test "a series ending after a count is needed until no occurrence could still be running" do
      assert {:series, ~U[2026-10-05 09:00:00Z], ~U[2026-11-17 10:00:00Z]} =
               EventVideoRoomTimes.for_event(timed("RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=3"))
    end

    test "a series with no end is never treated as over" do
      assert {:series, _lobby, nil} = EventVideoRoomTimes.for_event(timed("FREQ=WEEKLY;BYDAY=MO"))
    end

    test "a rule beyond what the grid's editor writes is never treated as over" do
      assert {:series, _lobby, nil} =
               EventVideoRoomTimes.for_event(timed("FREQ=MONTHLY;BYMONTHDAY=15;COUNT=2"))
    end

    # RFC 5545 skips months without a 31st: 31 August, 31 October, 31
    # December, four months rather than three.
    test "a monthly count from the 31st is never treated as over" do
      event = %{
        start_at: ~U[2026-08-31 09:00:00Z],
        end_at: ~U[2026-08-31 10:00:00Z],
        recurrence_rule: "FREQ=MONTHLY;COUNT=3"
      }

      assert {:series, _lobby, nil} = EventVideoRoomTimes.for_event(event)
    end

    # A yearly rule from 29 February repeats only in leap years.
    test "a yearly count from 29 February is never treated as over" do
      event = %{
        all_day: true,
        start_date: ~D[2028-02-29],
        end_date: ~D[2028-03-01],
        recurrence_rule: "FREQ=YEARLY;COUNT=2"
      }

      assert {:series, _lobby, nil} = EventVideoRoomTimes.for_event(event)
    end

    # The fifth Friday exists in only some months.
    test "a count over an ordinal weekday is never treated as over" do
      assert {:series, _lobby, nil} =
               EventVideoRoomTimes.for_event(timed("FREQ=MONTHLY;BYDAY=5FR;COUNT=2"))
    end

    test "a monthly count from an early day keeps its bound" do
      event = %{
        start_at: ~U[2026-08-03 09:00:00Z],
        end_at: ~U[2026-08-03 10:00:00Z],
        recurrence_rule: "FREQ=MONTHLY;COUNT=3"
      }

      assert {:series, _lobby, %DateTime{}} = EventVideoRoomTimes.for_event(event)
    end

    # Google and Outlook cache each occurrence under its parent, without the
    # series' rule.
    test "an occurrence row naming its parent is a series with no known end" do
      event = Map.put(timed(nil), :recurring_event_id, "parent-event")

      assert EventVideoRoomTimes.for_event(event) == {:series, ~U[2026-10-05 09:00:00Z], nil}
    end
  end

  describe "merge/2" do
    test "a one-off event's times follow the event" do
      assert EventVideoRoomTimes.merge(
               {~U[2026-10-05 09:00:00Z], ~U[2026-10-05 10:00:00Z]},
               {:exact, ~U[2026-10-01 09:00:00Z], ~U[2026-10-01 10:00:00Z]}
             ) == {~U[2026-10-01 09:00:00Z], ~U[2026-10-01 10:00:00Z]}
    end

    test "a series only ever opens its lobby earlier and moves its end later" do
      current = {~U[2026-10-05 09:00:00Z], ~U[2026-12-01 10:00:00Z]}

      assert EventVideoRoomTimes.merge(
               current,
               {:series, ~U[2026-10-12 09:00:00Z], ~U[2026-11-01 10:00:00Z]}
             ) == current

      assert EventVideoRoomTimes.merge(
               current,
               {:series, ~U[2026-10-01 09:00:00Z], ~U[2027-01-01 10:00:00Z]}
             ) == {~U[2026-10-01 09:00:00Z], ~U[2027-01-01 10:00:00Z]}
    end

    test "a series with no known end keeps its room with no end" do
      assert {_lobby, nil} =
               EventVideoRoomTimes.merge(
                 {~U[2026-10-05 09:00:00Z], ~U[2026-12-01 10:00:00Z]},
                 {:series, ~U[2026-10-05 09:00:00Z], nil}
               )
    end
  end

  defp timed(rule),
    do: %{
      all_day: false,
      start_at: ~U[2026-10-05 09:00:00Z],
      end_at: ~U[2026-10-05 10:00:00Z],
      recurrence_rule: rule
    }
end
