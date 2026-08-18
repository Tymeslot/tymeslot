defmodule Tymeslot.Integrations.Calendar.DebugScheduleTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.DebugSchedule

  @timezone "Europe/Berlin"

  # A fixed week in the future so day-of-week mapping is unambiguous:
  # 2026-06-29 is a Monday.
  @monday ~D[2026-06-29]
  @tuesday ~D[2026-06-30]
  @wednesday ~D[2026-07-01]
  @thursday ~D[2026-07-02]
  @saturday ~D[2026-07-04]

  defp range(%Date{} = from, %Date{} = to) do
    {DateTime.new!(from, ~T[00:00:00], @timezone), DateTime.new!(to, ~T[00:00:00], @timezone)}
  end

  defp summaries(events), do: Enum.map(events, & &1.summary)

  defp event(%Date{} = date, %Time{} = from, %Time{} = to, summary) do
    %{
      uid: "test-#{summary}",
      summary: summary,
      start_time: DateTime.new!(date, from, @timezone),
      end_time: DateTime.new!(date, to, @timezone),
      status: "confirmed"
    }
  end

  describe "events/5 with the :default pattern" do
    test "Monday yields the light recurring pair" do
      {start_dt, end_dt} = range(@monday, @tuesday)

      assert ["Monday Morning Standup", "Project Review"] =
               summaries(DebugSchedule.events(:default, [], start_dt, end_dt, @timezone))
    end

    test "Thursday is free and the weekend is free" do
      {start_dt, end_dt} = range(@thursday, Date.add(@thursday, 1))
      assert [] = DebugSchedule.events(:default, [], start_dt, end_dt, @timezone)

      {sat_start, sat_end} = range(@saturday, Date.add(@saturday, 1))
      assert [] = DebugSchedule.events(:default, [], sat_start, sat_end, @timezone)
    end

    test "events are keyed on day-of-week, so the pattern is relative to any week" do
      next_monday = Date.add(@monday, 7)
      {start_dt, end_dt} = range(next_monday, Date.add(next_monday, 1))

      assert ["Monday Morning Standup", "Project Review"] =
               summaries(DebugSchedule.events(:default, [], start_dt, end_dt, @timezone))
    end

    test "events carry the requested timezone and are sorted by start time" do
      {start_dt, end_dt} = range(@tuesday, Date.add(@tuesday, 1))
      events = DebugSchedule.events(:default, [], start_dt, end_dt, @timezone)

      assert length(events) == 5
      assert Enum.all?(events, &(&1.start_time.time_zone == @timezone))
      assert events == Enum.sort_by(events, & &1.start_time, DateTime)
    end
  end

  describe "events/5 with the :empty pattern" do
    test "produces no recurring events" do
      {start_dt, end_dt} = range(@monday, @saturday)
      assert [] = DebugSchedule.events(:empty, [], start_dt, end_dt, @timezone)
    end
  end

  describe "events/5 with explicit rules" do
    test "a block_date rule busies the whole day on top of the empty pattern" do
      {start_dt, end_dt} = range(@thursday, Date.add(@thursday, 1))

      assert [event] =
               DebugSchedule.events(
                 :empty,
                 [{:block_date, @thursday}],
                 start_dt,
                 end_dt,
                 @timezone
               )

      assert event.summary == "Blocked (dev)"
      assert event.start_time == DateTime.new!(@thursday, ~T[00:00:00], @timezone)
      assert event.end_time == DateTime.new!(Date.add(@thursday, 1), ~T[00:00:00], @timezone)
    end

    test "a busy rule adds a single period" do
      {start_dt, end_dt} = range(@thursday, Date.add(@thursday, 1))
      rule = {:busy, @thursday, ~T[10:00:00], ~T[11:00:00]}

      assert [event] = DebugSchedule.events(:empty, [rule], start_dt, end_dt, @timezone)
      assert event.summary == "Busy (dev)"
      assert event.start_time == DateTime.new!(@thursday, ~T[10:00:00], @timezone)
      assert event.end_time == DateTime.new!(@thursday, ~T[11:00:00], @timezone)
    end

    test "rules combine with the recurring pattern" do
      {start_dt, end_dt} = range(@wednesday, Date.add(@wednesday, 1))
      rule = {:busy, @wednesday, ~T[18:00:00], ~T[19:00:00]}

      summaries =
        summaries(DebugSchedule.events(:default, [rule], start_dt, end_dt, @timezone))

      assert "Company All-Hands" in summaries
      assert "Busy (dev)" in summaries
    end
  end

  describe "in_range/3" do
    test "keeps overlapping events and sorts them by start time" do
      {range_start, range_end} = range(@thursday, Date.add(@thursday, 1))

      inside_late = event(@thursday, ~T[15:00:00], ~T[16:00:00], "late")
      inside_early = event(@thursday, ~T[09:00:00], ~T[10:00:00], "early")
      outside = event(@saturday, ~T[09:00:00], ~T[10:00:00], "outside")

      assert ["early", "late"] =
               [inside_late, inside_early, outside]
               |> DebugSchedule.in_range(range_start, range_end)
               |> summaries()
    end
  end

  describe "events/5 range filtering" do
    test "includes an event that overlaps the window boundary" do
      # Window starts mid-way through the Wednesday all-hands (09:00–17:00).
      start_dt = DateTime.new!(@wednesday, ~T[12:00:00], @timezone)
      end_dt = DateTime.new!(Date.add(@wednesday, 1), ~T[00:00:00], @timezone)

      assert ["Company All-Hands"] =
               summaries(DebugSchedule.events(:default, [], start_dt, end_dt, @timezone))
    end
  end
end
