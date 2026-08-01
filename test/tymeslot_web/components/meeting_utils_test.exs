defmodule TymeslotWeb.Components.MeetingUtilsTest do
  use ExUnit.Case, async: true

  @moduletag :components

  alias TymeslotWeb.Components.MeetingUtils

  describe "normalize_slot_time/1" do
    test "returns ok for binary strings" do
      assert {:ok, "09:00"} = MeetingUtils.normalize_slot_time("09:00")
      assert {:ok, "14:30"} = MeetingUtils.normalize_slot_time("14:30")
    end

    test "formats Time structs" do
      {:ok, time} = Time.new(9, 0, 0)
      assert {:ok, "9:00 AM"} = MeetingUtils.normalize_slot_time(time)
    end

    test "formats NaiveDateTime structs using time component" do
      {:ok, ndt} = NaiveDateTime.new(2024, 1, 15, 9, 30, 0)
      assert {:ok, "9:30 AM"} = MeetingUtils.normalize_slot_time(ndt)
    end

    test "formats DateTime structs using time component" do
      {:ok, dt} = DateTime.new(~D[2024-01-15], ~T[14:00:00])
      assert {:ok, "2:00 PM"} = MeetingUtils.normalize_slot_time(dt)
    end

    test "uses wall-clock time from DateTime, not UTC-shifted" do
      # Create a DateTime at 14:00 in UTC+5 (wall clock 14:00, UTC 09:00)
      {:ok, dt_plus5} =
        DateTime.new(~D[2024-01-15], ~T[14:00:00], "Etc/GMT-5")

      # Create a DateTime at 14:00 in UTC (wall clock 14:00, UTC 14:00)
      {:ok, dt_utc} = DateTime.new(~D[2024-01-15], ~T[14:00:00])

      {:ok, result_plus5} = MeetingUtils.normalize_slot_time(dt_plus5)
      {:ok, result_utc} = MeetingUtils.normalize_slot_time(dt_utc)

      # Both have wall-clock time 14:00, so results should match
      assert result_plus5 == result_utc
    end

    test "returns error for nested map without time keys" do
      assert :error = MeetingUtils.normalize_slot_time(%{time: %{nested: "value"}})
    end

    test "extracts from map with atom :time key" do
      assert {:ok, "10:00"} = MeetingUtils.normalize_slot_time(%{time: "10:00"})
    end

    test "extracts from map with string \"time\" key" do
      assert {:ok, "10:00"} = MeetingUtils.normalize_slot_time(%{"time" => "10:00"})
    end

    test "extracts from map with atom :start_time key" do
      assert {:ok, "11:00"} = MeetingUtils.normalize_slot_time(%{start_time: "11:00"})
    end

    test "extracts from map with string \"start_time\" key" do
      assert {:ok, "11:00"} = MeetingUtils.normalize_slot_time(%{"start_time" => "11:00"})
    end

    test "returns error for nil" do
      assert :error = MeetingUtils.normalize_slot_time(nil)
    end

    test "returns error for integer" do
      assert :error = MeetingUtils.normalize_slot_time(42)
    end

    test "returns error for empty map" do
      assert :error = MeetingUtils.normalize_slot_time(%{})
    end
  end

  describe "normalize_slot_list/1" do
    test "normalizes legacy string slots to seat-aware maps" do
      assert [
               %{time: "09:00", seats_left: nil, capacity: nil},
               %{time: "10:00", seats_left: nil, capacity: nil}
             ] = MeetingUtils.normalize_slot_list(["09:00", "10:00"])
    end

    test "preserves seat data on enriched slot maps" do
      slots = [%{time: "09:00", seats_left: 4, capacity: 10}]

      assert [%{time: "09:00", seats_left: 4, capacity: 10}] =
               MeetingUtils.normalize_slot_list(slots)
    end

    test "treats maps without seat keys as solo slots" do
      assert [%{time: "11:00", seats_left: nil, capacity: nil}] =
               MeetingUtils.normalize_slot_list([%{start_time: "11:00"}])
    end

    test "filters out invalid slots" do
      assert [%{time: "09:00", seats_left: nil, capacity: nil}] =
               MeetingUtils.normalize_slot_list(["09:00", nil, 42])
    end

    test "handles empty list" do
      assert [] = MeetingUtils.normalize_slot_list([])
    end

    test "handles non-list input" do
      assert [] = MeetingUtils.normalize_slot_list(nil)
      assert [] = MeetingUtils.normalize_slot_list("09:00")
    end

    test "handles mixed Time structs and strings" do
      slots = [~T[09:00:00], "10:30"]

      # `Time` structs are formatted via `Display.format_time_for_display/1`,
      # which always renders 12h AM/PM regardless of locale — only strings
      # pass through as-is.
      assert [%{time: "9:00 AM", seats_left: nil}, %{time: "10:30", seats_left: nil}] =
               MeetingUtils.normalize_slot_list(slots)
    end
  end
end
