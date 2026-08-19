defmodule Tymeslot.Availability.TimeSlotsTest do
  @moduledoc """
  Tests for the TimeSlots module - pure functions for time slot generation.
  """

  use ExUnit.Case, async: true
  @moduletag :availability

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

    test "parses URL slug format (N-minutes)" do
      assert TimeSlots.parse_duration("60-minutes") == 60
      assert TimeSlots.parse_duration("45-minutes") == 45
      assert TimeSlots.parse_duration("15-minutes") == 15
    end

    test "parses 'minutes' variant without hyphen" do
      assert TimeSlots.parse_duration("30minutes") == 30
      assert TimeSlots.parse_duration("60 minutes") == 60
    end

    test "parses 'minute' singular" do
      assert TimeSlots.parse_duration("1min") == 1
      assert TimeSlots.parse_duration("1-minute") == 1
    end

    test "defaults to 30 for zero or negative" do
      assert TimeSlots.parse_duration("0") == 30
      assert TimeSlots.parse_duration("0min") == 30
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

  describe "generate_slots_for_range_with_breaks/5 across DST transitions" do
    # Europe/London falls back at 02:00 BST on 2026-10-25, so wall-clock
    # 01:00–01:59 happens twice. A break at 01:30 would crash DateTime.new!/3.
    test "resolves ambiguous break times on fall-back day without raising" do
      date = ~D[2026-10-25]
      start_dt = DateTime.new!(date, ~T[09:00:00], "Europe/London")
      end_dt = DateTime.new!(date, ~T[12:00:00], "Europe/London")
      breaks = [{~T[01:30:00], ~T[01:45:00]}]

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, breaks)

      assert length(slots) == 6
      assert "9:00 AM" in slots
      assert "11:30 AM" in slots
    end

    # Europe/London springs forward at 01:00 GMT on 2026-03-29, so wall-clock
    # 01:00–01:59 never happens. A break at 01:30 would crash DateTime.new!/3.
    test "resolves break times in spring-forward gap without raising" do
      date = ~D[2026-03-29]
      start_dt = DateTime.new!(date, ~T[09:00:00], "Europe/London")
      end_dt = DateTime.new!(date, ~T[12:00:00], "Europe/London")
      breaks = [{~T[01:30:00], ~T[01:45:00]}]

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, breaks)

      assert length(slots) == 6
      assert "9:00 AM" in slots
      assert "11:30 AM" in slots
    end

    # America/Santiago springs forward at 24:00 on 2026-09-05, so wall-clock
    # 00:00–00:59 never happens on 2026-09-06. An owner far enough east (e.g.
    # Asia/Macau) pushes availability over the attendee's midnight, so the day
    # boundary is built at 00:00 — which would crash DateTime.new!/3.
    test "resolves a midnight start boundary that falls in a spring-forward gap" do
      date = ~D[2026-09-06]
      start_dt = DateTime.new!(~D[2026-09-05], ~T[21:00:00], "America/Santiago")
      end_dt = DateTime.new!(date, ~T[05:00:00], "America/Santiago")

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [])

      # The day starts at 01:00, not midnight — the gap is snapped forward.
      assert List.first(slots) == "1:00 AM"
      refute "12:00 AM" in slots
      assert length(slots) == 8
    end

    # America/Santiago falls back at 24:00 on 2026-04-04, so wall-clock
    # 23:00–23:59 happens twice and 23:59:59 is ambiguous. DateTime.new!/3
    # raises on ambiguity just as it does on a gap.
    test "resolves an end-of-day boundary that is ambiguous on a fall-back day" do
      date = ~D[2026-04-04]
      start_dt = DateTime.new!(date, ~T[20:00:00], "America/Santiago")
      end_dt = DateTime.new!(~D[2026-04-05], ~T[03:00:00], "America/Santiago")

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [])

      assert List.first(slots) == "8:00 PM"
      assert List.last(slots) == "11:00 PM"
      assert length(slots) == 7
    end

    # Both boundaries are built when availability covers the attendee's whole
    # day, so a gap at midnight must not take the end boundary down with it.
    test "resolves both boundaries when a full day spans a spring-forward gap" do
      date = ~D[2026-09-06]
      start_dt = DateTime.new!(~D[2026-09-05], ~T[20:00:00], "America/Santiago")
      end_dt = DateTime.new!(~D[2026-09-07], ~T[03:00:00], "America/Santiago")

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [])

      assert List.first(slots) == "1:00 AM"
      assert List.last(slots) == "11:00 PM"
      assert length(slots) == 45
    end

    # Ambiguous breaks are still honoured at the first (earlier UTC) occurrence.
    test "ambiguous break still filters an overlapping slot" do
      date = ~D[2026-10-25]
      start_dt = DateTime.new!(date, ~T[09:00:00], "Europe/London")
      end_dt = DateTime.new!(date, ~T[12:00:00], "Europe/London")
      # A break at wall-clock 10:30–11:00 is unambiguous and must still apply
      # — proves resolve_wall_time doesn't silently drop usable breaks.
      breaks = [{~T[10:30:00], ~T[11:00:00]}]

      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, breaks)

      refute "10:30 AM" in slots
      assert "10:00 AM" in slots
      assert "11:00 AM" in slots
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

  describe "generate_slots_for_range_with_breaks/6 with an explicit interval" do
    setup do
      date = ~D[2026-06-15]
      {:ok, start_dt} = DateTime.new(date, ~T[09:00:00], "Europe/London")
      {:ok, end_dt} = DateTime.new(date, ~T[10:00:00], "Europe/London")

      %{date: date, start_dt: start_dt, end_dt: end_dt}
    end

    test "an interval shorter than the duration produces overlapping starts",
         %{date: date, start_dt: start_dt, end_dt: end_dt} do
      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [], 5)

      assert List.first(slots) == "9:00 AM"
      assert List.last(slots) == "9:30 AM"
      assert length(slots) == 7
      assert "9:05 AM" in slots
    end

    test "an interval longer than the duration produces fewer, rounder starts",
         %{date: date, start_dt: start_dt, end_dt: end_dt} do
      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 20, date, [], 60)

      assert slots == ["9:00 AM"]
    end

    test "an interval that does not divide the window is still bounded by it",
         %{date: date, start_dt: start_dt, end_dt: end_dt} do
      slots = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [], 7)

      assert List.first(slots) == "9:00 AM"
      assert "9:07 AM" in slots
      # Last start must still leave room for the full 30-minute meeting.
      assert List.last(slots) == "9:28 AM"
    end

    test "a window shorter than the duration offers nothing regardless of interval",
         %{date: date, start_dt: start_dt} do
      {:ok, short_end} = DateTime.new(date, ~T[09:10:00], "Europe/London")

      assert TimeSlots.generate_slots_for_range_with_breaks(start_dt, short_end, 30, date, [], 5) ==
               []
    end

    test "a nil interval falls back to the duration",
         %{date: date, start_dt: start_dt, end_dt: end_dt} do
      with_nil =
        TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [], nil)

      without = TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, [])

      assert with_nil == without
    end

    test "breaks are filtered by the meeting's length, not by the interval",
         %{date: date, start_dt: start_dt, end_dt: end_dt} do
      breaks = [{~T[09:20:00], ~T[09:30:00]}]

      slots =
        TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, 30, date, breaks, 5)

      # A 30-minute meeting starting at 9:00 runs to 9:30 and so overlaps the
      # break; every start before the break ends is excluded.
      refute "9:00 AM" in slots
      assert "9:30 AM" in slots
    end

    test "an explicit interval equal to the duration reproduces the default grid exactly",
         %{date: date} do
      {:ok, start_dt} = DateTime.new(date, ~T[09:00:00], "Europe/London")

      for duration <- [15, 20, 30, 45, 60],
          window_minutes <- [30, 60, 90, 125, 240] do
        {:ok, end_dt} = DateTime.new(date, ~T[09:00:00], "Europe/London")
        end_dt = DateTime.add(end_dt, window_minutes, :minute)

        generalised =
          TimeSlots.generate_slots_for_range_with_breaks(
            start_dt,
            end_dt,
            duration,
            date,
            [],
            duration
          )

        default =
          TimeSlots.generate_slots_for_range_with_breaks(start_dt, end_dt, duration, date, [])

        assert generalised == default,
               "interval == duration must reproduce the default grid " <>
                 "(duration #{duration}, window #{window_minutes})"
      end
    end
  end
end
