defmodule Tymeslot.Availability.TimeSlotsTest do
  @moduledoc """
  Tests for the TimeSlots module - pure functions for time slot generation.
  """

  use ExUnit.Case, async: true

  alias Tymeslot.Availability.TimeSlots

  describe "format_datetime_slot/1" do
    test "formats midnight correctly" do
      datetime = DateTime.new!(~D[2025-06-15], ~T[00:00:00], "Etc/UTC")
      assert TimeSlots.format_datetime_slot(datetime) == "12:00 AM"
    end

    test "formats morning times correctly" do
      datetime = DateTime.new!(~D[2025-06-15], ~T[09:00:00], "Etc/UTC")
      assert TimeSlots.format_datetime_slot(datetime) == "9:00 AM"
    end

    test "formats 11:30 AM correctly" do
      datetime = DateTime.new!(~D[2025-06-15], ~T[11:30:00], "Etc/UTC")
      assert TimeSlots.format_datetime_slot(datetime) == "11:30 AM"
    end

    test "formats noon correctly" do
      datetime = DateTime.new!(~D[2025-06-15], ~T[12:00:00], "Etc/UTC")
      assert TimeSlots.format_datetime_slot(datetime) == "12:00 PM"
    end

    test "formats afternoon times correctly" do
      datetime = DateTime.new!(~D[2025-06-15], ~T[14:30:00], "Etc/UTC")
      assert TimeSlots.format_datetime_slot(datetime) == "2:30 PM"
    end

    test "formats evening times correctly" do
      datetime = DateTime.new!(~D[2025-06-15], ~T[21:15:00], "Etc/UTC")
      assert TimeSlots.format_datetime_slot(datetime) == "9:15 PM"
    end

    test "formats 11:59 PM correctly" do
      datetime = DateTime.new!(~D[2025-06-15], ~T[23:59:00], "Etc/UTC")
      assert TimeSlots.format_datetime_slot(datetime) == "11:59 PM"
    end

    test "pads single-digit minutes with zero" do
      datetime = DateTime.new!(~D[2025-06-15], ~T[09:05:00], "Etc/UTC")
      assert TimeSlots.format_datetime_slot(datetime) == "9:05 AM"
    end
  end

  describe "parse_time_slot/1" do
    test "parses morning time" do
      assert %Time{hour: 9, minute: 0} = TimeSlots.parse_time_slot("9:00 AM")
    end

    test "parses noon" do
      assert %Time{hour: 12, minute: 0} = TimeSlots.parse_time_slot("12:00 PM")
    end

    test "parses midnight" do
      assert %Time{hour: 0, minute: 0} = TimeSlots.parse_time_slot("12:00 AM")
    end

    test "parses afternoon time" do
      assert %Time{hour: 14, minute: 30} = TimeSlots.parse_time_slot("2:30 PM")
    end

    test "parses evening time" do
      assert %Time{hour: 21, minute: 15} = TimeSlots.parse_time_slot("9:15 PM")
    end

    test "raises on invalid format" do
      assert_raise ArgumentError, fn ->
        TimeSlots.parse_time_slot("invalid")
      end
    end
  end

  describe "parse_duration/1" do
    test "parses integer duration" do
      assert TimeSlots.parse_duration(30) == 30
      assert TimeSlots.parse_duration(60) == 60
      assert TimeSlots.parse_duration(15) == 15
    end

    test "parses '30min' format" do
      assert TimeSlots.parse_duration("30min") == 30
    end

    test "parses '60min' format" do
      assert TimeSlots.parse_duration("60min") == 60
    end

    test "parses '15min' format" do
      assert TimeSlots.parse_duration("15min") == 15
    end

    test "parses plain number string" do
      assert TimeSlots.parse_duration("30") == 30
      assert TimeSlots.parse_duration("60") == 60
    end

    test "handles whitespace" do
      assert TimeSlots.parse_duration("  30  ") == 30
      assert TimeSlots.parse_duration(" 60 min ") == 60
    end

    test "defaults to 30 for invalid format" do
      assert TimeSlots.parse_duration("invalid") == 30
      assert TimeSlots.parse_duration("abc") == 30
    end

    test "handles case insensitivity" do
      assert TimeSlots.parse_duration("30MIN") == 30
      assert TimeSlots.parse_duration("60Min") == 60
    end
  end

  describe "generate_slots_for_range/4" do
    test "generates correct number of 30-minute slots" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[12:00:00])

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 30, date)

      # 3 hours = 6 slots of 30 min each
      assert length(slots) == 6
      assert "9:00 AM" in slots
      assert "9:30 AM" in slots
      assert "10:00 AM" in slots
      assert "10:30 AM" in slots
      assert "11:00 AM" in slots
      assert "11:30 AM" in slots
    end

    test "generates correct number of 60-minute slots" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[12:00:00])

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 60, date)

      # 3 hours = 3 slots of 60 min each
      assert length(slots) == 3
      assert "9:00 AM" in slots
      assert "10:00 AM" in slots
      assert "11:00 AM" in slots
    end

    test "generates correct number of 15-minute slots" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[10:00:00])

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 15, date)

      # 1 hour = 4 slots of 15 min each
      assert length(slots) == 4
    end

    test "returns empty list when duration exceeds available time" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[09:15:00])

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 30, date)

      assert slots == []
    end

    test "handles afternoon slots" do
      {start_dt, end_dt, date} = slot_range(~T[14:00:00], ~T[16:00:00])

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 30, date)

      assert "2:00 PM" in slots
      assert "2:30 PM" in slots
      assert "3:00 PM" in slots
      assert "3:30 PM" in slots
    end
  end

  describe "generate_slots_for_range_with_breaks/5" do
    test "generates slots without breaks" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[12:00:00])

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [])

      assert length(slots) == 6
    end

    test "excludes slots during break period" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[12:00:00])

      # Break from 10:00 to 10:30
      breaks = [{~T[10:00:00], ~T[10:30:00]}]

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, breaks)

      # Should exclude the 10:00 AM slot
      refute "10:00 AM" in slots
      assert "9:00 AM" in slots
      assert "9:30 AM" in slots
      assert "10:30 AM" in slots
      assert "11:00 AM" in slots
      assert "11:30 AM" in slots
    end

    test "excludes multiple slots overlapping with break" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[12:00:00])

      # Break from 10:00 to 11:00 (excludes 10:00 and 10:30 for 30-min slots)
      breaks = [{~T[10:00:00], ~T[11:00:00]}]

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, breaks)

      refute "10:00 AM" in slots
      refute "10:30 AM" in slots
      assert "9:00 AM" in slots
      assert "9:30 AM" in slots
      assert "11:00 AM" in slots
      assert "11:30 AM" in slots
    end

    test "handles multiple break periods" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[14:00:00])

      # Morning break (10:00-10:30) and lunch break (12:00-13:00)
      breaks = [
        {~T[10:00:00], ~T[10:30:00]},
        {~T[12:00:00], ~T[13:00:00]}
      ]

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, breaks)

      refute "10:00 AM" in slots
      refute "12:00 PM" in slots
      refute "12:30 PM" in slots
      assert "9:00 AM" in slots
      assert "10:30 AM" in slots
      assert "1:00 PM" in slots
    end

    test "handles slot that partially overlaps with break at start" do
      {start_dt, end_dt, date} = slot_range(~T[09:00:00], ~T[12:00:00])

      # Break from 10:15 to 10:45 - the 10:00 slot would end at 10:30, overlapping
      breaks = [{~T[10:15:00], ~T[10:45:00]}]

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, breaks)

      # 10:00 slot runs 10:00-10:30 which overlaps with break starting at 10:15
      refute "10:00 AM" in slots
      # 10:30 slot runs 10:30-11:00 which overlaps with break ending at 10:45
      refute "10:30 AM" in slots
    end
  end

  describe "edge cases" do
    test "handles date mismatch - selected date before range" do
      start_dt = DateTime.new!(~D[2025-06-16], ~T[09:00:00], "Etc/UTC")
      end_dt = DateTime.new!(~D[2025-06-16], ~T[12:00:00], "Etc/UTC")
      date = ~D[2025-06-15]

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 30, date)

      # No slots should be generated since selected date is before the range
      assert slots == []
    end

    test "handles date mismatch - selected date after range" do
      start_dt = DateTime.new!(~D[2025-06-14], ~T[09:00:00], "Etc/UTC")
      end_dt = DateTime.new!(~D[2025-06-14], ~T[12:00:00], "Etc/UTC")
      date = ~D[2025-06-15]

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 30, date)

      # No slots should be generated since selected date is after the range
      assert slots == []
    end

    test "handles range spanning from previous day" do
      # Range from late night June 14 to early morning June 15
      start_dt = DateTime.new!(~D[2025-06-14], ~T[22:00:00], "Etc/UTC")
      end_dt = DateTime.new!(~D[2025-06-15], ~T[02:00:00], "Etc/UTC")
      date = ~D[2025-06-15]

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 30, date)

      # Should only include slots from midnight to 2:00 AM on June 15
      assert "12:00 AM" in slots
      assert "12:30 AM" in slots
      assert "1:00 AM" in slots
      assert "1:30 AM" in slots
      # Should NOT include slots from June 14
      refute "10:00 PM" in slots
    end

    test "handles range spanning to next day" do
      # Range from June 15 evening into June 16
      start_dt = DateTime.new!(~D[2025-06-15], ~T[22:00:00], "Etc/UTC")
      end_dt = DateTime.new!(~D[2025-06-16], ~T[02:00:00], "Etc/UTC")
      date = ~D[2025-06-15]

      slots = TimeSlots.generate_slots_for_range(start_dt, end_dt, 30, date)

      # Should include slots from 10 PM until end of day
      # Note: slots are limited to the selected date (up to 23:59:59)
      # So only slots that fit within June 15 are included
      assert "10:00 PM" in slots
      assert "10:30 PM" in slots
      assert "11:00 PM" in slots
      # 11:30 PM is excluded because a 30-min meeting would end at 12:00 AM next day
      assert length(slots) == 3
    end
  end

  defp slot_range(start_time, end_time, date \\ ~D[2025-06-15]) do
    start_dt = DateTime.new!(date, start_time, "Etc/UTC")
    end_dt = DateTime.new!(date, end_time, "Etc/UTC")
    {start_dt, end_dt, date}
  end
end
