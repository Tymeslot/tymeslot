defmodule TymeslotWeb.Themes.Shared.SlotGroupingTest do
  use ExUnit.Case, async: true

  alias TymeslotWeb.Themes.Shared.SlotGrouping

  @moduletag :themes
  @moduletag :unit

  describe "two_tier?/2" do
    test "is false when no interval is set" do
      refute SlotGrouping.two_tier?(nil, 30)
    end

    test "is false when the interval equals the duration" do
      refute SlotGrouping.two_tier?(30, 30)
    end

    test "is false when the interval is longer than the duration" do
      refute SlotGrouping.two_tier?(60, 30)
    end

    test "is true only when the interval is shorter than the duration" do
      assert SlotGrouping.two_tier?(5, 30)
    end
  end

  describe "group/3" do
    test "returns the flat period grouping when not two-tier" do
      assert {:flat, periods} = SlotGrouping.group(["9:00 AM", "9:30 AM"], nil, 30)

      assert {"Morning", ["9:00 AM", "9:30 AM"]} in periods
    end

    test "nests hours inside periods when two-tier" do
      slots = ["9:00 AM", "9:05 AM", "10:00 AM"]

      assert {:hours, periods} = SlotGrouping.group(slots, 5, 30)

      morning = Enum.find_value(periods, fn {label, hours} -> label == "Morning" && hours end)

      assert morning == [{9, ["9:00 AM", "9:05 AM"]}, {10, ["10:00 AM"]}]
    end

    test "groups an interval that does not divide the hour into uneven hours" do
      slots = ["9:00 AM", "9:50 AM", "10:40 AM"]

      assert {:hours, periods} = SlotGrouping.group(slots, 50, 60)

      morning = Enum.find_value(periods, fn {label, hours} -> label == "Morning" && hours end)

      assert morning == [{9, ["9:00 AM", "9:50 AM"]}, {10, ["10:40 AM"]}]
    end
  end

  describe "effective_expanded_hour/2" do
    test "expands the earliest hour holding slots when nothing is chosen" do
      grouping = SlotGrouping.group(["2:00 PM", "9:05 AM"], 5, 30)

      assert SlotGrouping.effective_expanded_hour(nil, grouping) == 9
    end

    test "expands nothing when the booker has collapsed the open hour" do
      grouping = SlotGrouping.group(["9:05 AM"], 5, 30)

      assert SlotGrouping.effective_expanded_hour(:none, grouping) == nil
    end

    test "expands the chosen hour" do
      grouping = SlotGrouping.group(["9:05 AM", "2:00 PM"], 5, 30)

      assert SlotGrouping.effective_expanded_hour(14, grouping) == 14
    end

    test "expands nothing when there are no slots at all" do
      grouping = SlotGrouping.group([], 5, 30)

      assert SlotGrouping.effective_expanded_hour(nil, grouping) == nil
    end

    test "falls back to the earliest hour when the stored hour holds no slots in this grouping" do
      # A refetch that keeps the same date (timezone change, retry) can leave
      # a previously stored hour (11) with nothing in the new grouping.
      grouping = SlotGrouping.group(["9:05 AM", "2:00 PM"], 5, 30)

      assert SlotGrouping.effective_expanded_hour(11, grouping) == 9
    end

    test "falls back to the earliest hour for an out-of-range visitor-supplied hour" do
      grouping = SlotGrouping.group(["9:05 AM", "2:00 PM"], 5, 30)

      assert SlotGrouping.effective_expanded_hour(47, grouping) == 9
    end
  end
end
