defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.MonthSpanLayoutTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.MonthSpanLayout

  # The week under test runs Monday 6 April → Sunday 12 April 2026, so column
  # indices map: Apr 6 → 0, Apr 7 → 1, … Apr 12 → 6.
  @week Enum.map(0..6, &Date.add(~D[2026-04-06], &1))

  defp assigns(events), do: %{user_timezone: "Etc/UTC", visible_events: events}

  defp all_day(id, start_date, end_date) do
    %{id: id, summary: "all-#{id}", all_day: true, start_date: start_date, end_date: end_date}
  end

  defp timed(id, start_at, end_at) do
    %{id: id, summary: "timed-#{id}", all_day: false, start_at: start_at, end_at: end_at}
  end

  defp seg_for(layout, id), do: Enum.find(layout.segments, &(&1.event.id == id))

  describe "week_layout/2 — bars" do
    test "an all-day event renders as a bar (and is never dropped)" do
      # end_date is exclusive, so Apr 7–9 inclusive.
      layout =
        MonthSpanLayout.week_layout(assigns([all_day(1, ~D[2026-04-07], ~D[2026-04-10])]), @week)

      assert %{start_col: 1, end_col: 3, lane: 0, continues_left: false, continues_right: false} =
               seg_for(layout, 1)

      assert layout.lane_count == 1
    end

    test "a single-day all-day event is a one-column bar" do
      layout =
        MonthSpanLayout.week_layout(assigns([all_day(1, ~D[2026-04-08], ~D[2026-04-09])]), @week)

      assert %{start_col: 2, end_col: 2} = seg_for(layout, 1)
    end

    test "a multi-day timed event spans the days it covers" do
      # 7 Apr 22:00 → 9 Apr 02:00 covers Apr 7, 8, 9.
      event = timed(1, ~U[2026-04-07 22:00:00Z], ~U[2026-04-09 02:00:00Z])
      layout = MonthSpanLayout.week_layout(assigns([event]), @week)
      assert %{start_col: 1, end_col: 3} = seg_for(layout, 1)
    end

    test "overlapping bars are packed into separate lanes" do
      events = [
        all_day(1, ~D[2026-04-07], ~D[2026-04-10]),
        timed(2, ~U[2026-04-07 22:00:00Z], ~U[2026-04-09 02:00:00Z])
      ]

      layout = MonthSpanLayout.week_layout(assigns(events), @week)

      assert layout.lane_count == 2
      assert seg_for(layout, 1).lane != seg_for(layout, 2).lane
    end

    test "non-overlapping bars reuse the same lane" do
      events = [
        all_day(1, ~D[2026-04-06], ~D[2026-04-08]),
        all_day(2, ~D[2026-04-09], ~D[2026-04-12])
      ]

      layout = MonthSpanLayout.week_layout(assigns(events), @week)

      assert layout.lane_count == 1
      assert seg_for(layout, 1).lane == 0
      assert seg_for(layout, 2).lane == 0
    end

    test "a bar crossing the week boundary is clipped and flagged open-ended" do
      # Apr 9 → Apr 14 (exclusive 15) extends past the Sunday Apr 12 edge.
      layout =
        MonthSpanLayout.week_layout(assigns([all_day(1, ~D[2026-04-09], ~D[2026-04-15])]), @week)

      assert %{start_col: 3, end_col: 6, continues_left: false, continues_right: true} =
               seg_for(layout, 1)
    end
  end

  describe "chip_events/2 — single-day timed events" do
    test "returns single-day timed events for the day, excluding bars" do
      events = [
        all_day(1, ~D[2026-04-07], ~D[2026-04-10]),
        timed(2, ~U[2026-04-08 11:00:00Z], ~U[2026-04-08 12:00:00Z]),
        timed(3, ~U[2026-04-07 22:00:00Z], ~U[2026-04-09 02:00:00Z])
      ]

      chips = MonthSpanLayout.chip_events(assigns(events), ~D[2026-04-08])

      assert [%{id: 2}] = chips
    end

    test "a timed event ending exactly at local midnight stays a single-day chip" do
      # 8 Apr 10:00 → 9 Apr 00:00 belongs to Apr 8 only, not Apr 9.
      event = timed(1, ~U[2026-04-08 10:00:00Z], ~U[2026-04-09 00:00:00Z])
      a = assigns([event])

      assert [%{id: 1}] = MonthSpanLayout.chip_events(a, ~D[2026-04-08])
      assert [] = MonthSpanLayout.chip_events(a, ~D[2026-04-09])
      assert MonthSpanLayout.week_layout(a, @week).segments == []
    end
  end
end
