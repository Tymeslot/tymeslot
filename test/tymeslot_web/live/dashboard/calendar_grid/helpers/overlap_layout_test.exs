defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.OverlapLayoutTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.OverlapLayout

  describe "overlap_layout/1" do
    test "empty list returns empty" do
      assert OverlapLayout.overlap_layout([]) == []
    end

    test "non-overlapping events get separate columns" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 10:00:00Z]}
      e2 = %{start_at: ~U[2026-03-12 11:00:00Z], end_at: ~U[2026-03-12 12:00:00Z]}

      result = OverlapLayout.overlap_layout([e1, e2])
      # Both fit in column 0 since they don't overlap
      assert [{^e1, 0, 1}, {^e2, 0, 1}] = result
    end

    test "two overlapping events get different columns" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 10:30:00Z]}
      e2 = %{start_at: ~U[2026-03-12 10:00:00Z], end_at: ~U[2026-03-12 11:00:00Z]}

      result = OverlapLayout.overlap_layout([e1, e2])
      assert [{^e1, 0, 2}, {^e2, 1, 2}] = result
    end

    test "three overlapping events each get their own column" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 11:00:00Z]}
      e2 = %{start_at: ~U[2026-03-12 09:30:00Z], end_at: ~U[2026-03-12 11:30:00Z]}
      e3 = %{start_at: ~U[2026-03-12 10:00:00Z], end_at: ~U[2026-03-12 12:00:00Z]}

      result = OverlapLayout.overlap_layout([e1, e2, e3])
      assert [{^e1, 0, 3}, {^e2, 1, 3}, {^e3, 2, 3}] = result
    end

    test "event after a gap reuses an earlier column" do
      e1 = %{start_at: ~U[2026-03-12 09:00:00Z], end_at: ~U[2026-03-12 10:00:00Z]}
      e2 = %{start_at: ~U[2026-03-12 09:30:00Z], end_at: ~U[2026-03-12 10:30:00Z]}
      # e3 starts after e1 ends — can reuse column 0
      e3 = %{start_at: ~U[2026-03-12 10:00:00Z], end_at: ~U[2026-03-12 11:00:00Z]}

      result = OverlapLayout.overlap_layout([e1, e2, e3])
      # e3 reuses col 0 since e1 ended at 10:00 (not :gt comparison boundary).
      # Output is ordered by column index, so col-0 events (e1, e3) precede col-1 (e2).
      assert [{^e1, 0, 2}, {^e3, 0, 2}, {^e2, 1, 2}] = result
    end
  end
end
