defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.OverlapLayoutTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.OverlapLayout

  describe "overlap_layout/1" do
    test "empty list returns empty" do
      assert OverlapLayout.overlap_layout([]) == {[], []}
    end

    test "non-overlapping events get separate columns" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 10:00:00Z]}
      e2 = %{start_at: ~U[2026-03-12 11:00:00Z], end_at: ~U[2026-03-12 12:00:00Z]}

      assert {[{^e1, 0, 1}, {^e2, 0, 1}], []} = OverlapLayout.overlap_layout([e1, e2])
    end

    test "two overlapping events get different columns" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 10:30:00Z]}
      e2 = %{start_at: ~U[2026-03-12 10:00:00Z], end_at: ~U[2026-03-12 11:00:00Z]}

      assert {[{^e1, 0, 2}, {^e2, 1, 2}], []} = OverlapLayout.overlap_layout([e1, e2])
    end

    test "three overlapping events each get their own column" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 11:00:00Z]}
      e2 = %{start_at: ~U[2026-03-12 09:30:00Z], end_at: ~U[2026-03-12 11:30:00Z]}
      e3 = %{start_at: ~U[2026-03-12 10:00:00Z], end_at: ~U[2026-03-12 12:00:00Z]}

      assert {[{^e1, 0, 3}, {^e2, 1, 3}, {^e3, 2, 3}], []} =
               OverlapLayout.overlap_layout([e1, e2, e3])
    end

    test "event after a gap reuses an earlier column" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 10:00:00Z]}
      e2 = %{start_at: ~U[2026-03-12 09:30:00Z], end_at: ~U[2026-03-12 10:30:00Z]}
      # e3 starts after e1 ends — can reuse column 0
      e3 = %{start_at: ~U[2026-03-12 10:00:00Z], end_at: ~U[2026-03-12 11:00:00Z]}

      # e3 reuses col 0 since e1 ended at 10:00 (not :gt comparison boundary).
      # Output is ordered by column index, so col-0 events (e1, e3) precede col-1 (e2).
      assert {[{^e1, 0, 2}, {^e3, 0, 2}, {^e2, 1, 2}], []} =
               OverlapLayout.overlap_layout([e1, e2, e3])
    end

    test "four overlapping events: first three render, fourth overflows" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 12:00:00Z]}
      e2 = %{start_at: ~U[2026-03-12 09:30:00Z], end_at: ~U[2026-03-12 11:00:00Z]}
      e3 = %{start_at: ~U[2026-03-12 10:00:00Z], end_at: ~U[2026-03-12 11:30:00Z]}
      e4 = %{start_at: ~U[2026-03-12 10:15:00Z], end_at: ~U[2026-03-12 11:15:00Z]}

      assert {visible, [^e4]} = OverlapLayout.overlap_layout([e1, e2, e3, e4])
      # Visible events should all report the capped total_cols of 3.
      assert Enum.all?(visible, fn {_e, _idx, total} -> total == 3 end)
      assert length(visible) == 3
    end
  end

  # Santiago moves its clocks from 00:00 to 01:00 on 6 September 2026, so
  # that day has no midnight and begins at 01:00 (-03).
  describe "day_boundary_utc/2" do
    test "starts a day whose midnight the clocks skip where it begins" do
      assert OverlapLayout.day_boundary_utc(~D[2026-09-06], "America/Santiago") ==
               {~U[2026-09-06 04:00:00Z], ~U[2026-09-07 03:00:00Z]}
    end

    test "ends the day before at that same instant" do
      assert {_start, ~U[2026-09-06 04:00:00Z]} =
               OverlapLayout.day_boundary_utc(~D[2026-09-05], "America/Santiago")
    end

    # Havana moves its clocks back from 01:00 to 00:00 on 1 November 2026, so
    # that day has two midnights; it begins at the first (-04) and runs 25 hours.
    test "starts a day with two midnights at the first" do
      assert OverlapLayout.day_boundary_utc(~D[2026-11-01], "America/Havana") ==
               {~U[2026-11-01 04:00:00Z], ~U[2026-11-02 05:00:00Z]}

      assert {_start, ~U[2026-11-01 04:00:00Z]} =
               OverlapLayout.day_boundary_utc(~D[2026-10-31], "America/Havana")
    end
  end

  # 6 March 2027 in New York (-05:00) runs from 05:00Z to 05:00Z the next day.
  describe "event_spans_day?/3" do
    @tz "America/New_York"
    @day ~D[2027-03-06]
    @midnight ~U[2027-03-06 05:00:00Z]

    defp timed(start_at, end_at), do: %{start_at: start_at, end_at: end_at}

    test "puts an event with no length at the day's midnight in that day only" do
      moment = timed(@midnight, @midnight)

      assert OverlapLayout.event_spans_day?(moment, @day, @tz)
      refute OverlapLayout.event_spans_day?(moment, Date.add(@day, -1), @tz)
    end

    test "leaves out of the day an event ending exactly as it starts" do
      before = timed(DateTime.add(@midnight, -1, :hour), @midnight)

      refute OverlapLayout.event_spans_day?(before, @day, @tz)
      assert OverlapLayout.event_spans_day?(before, Date.add(@day, -1), @tz)
    end

    test "puts an event running across midnight in both days" do
      across = timed(DateTime.add(@midnight, -1, :hour), DateTime.add(@midnight, 1, :hour))

      assert OverlapLayout.event_spans_day?(across, @day, @tz)
      assert OverlapLayout.event_spans_day?(across, Date.add(@day, -1), @tz)
    end
  end
end
