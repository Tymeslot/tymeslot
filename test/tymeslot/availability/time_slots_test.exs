defmodule Tymeslot.Availability.TimeSlotsTest do
  @moduledoc """
  Tests for the TimeSlots module - pure functions for time slot generation.
  """

  use ExUnit.Case, async: true
  @moduletag :availability

  import Tymeslot.Test.SlotGridHelpers

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

  describe "a single window's slots" do
    test "generates slots without breaks" do
      slots = day_labels(~T[09:00:00], ~T[12:00:00])

      assert length(slots) == 6
    end

    test "excludes slots during break period" do
      # Break from 10:00 to 10:30
      slots = day_labels(~T[09:00:00], ~T[12:00:00], breaks: [{~T[10:00:00], ~T[10:30:00]}])

      # Should exclude the 10:00 AM slot
      refute "10:00 AM" in slots
      assert "9:00 AM" in slots
      assert "9:30 AM" in slots
      assert "10:30 AM" in slots
      assert "11:00 AM" in slots
      assert "11:30 AM" in slots
    end

    test "excludes multiple slots overlapping with break" do
      # Break from 10:00 to 11:00 (excludes 10:00 and 10:30 for 30-min slots)
      slots = day_labels(~T[09:00:00], ~T[12:00:00], breaks: [{~T[10:00:00], ~T[11:00:00]}])

      refute "10:00 AM" in slots
      refute "10:30 AM" in slots
      assert "9:00 AM" in slots
      assert "9:30 AM" in slots
      assert "11:00 AM" in slots
      assert "11:30 AM" in slots
    end

    test "handles multiple break periods" do
      # Morning break (10:00-10:30) and lunch break (12:00-13:00)
      slots =
        day_labels(~T[09:00:00], ~T[14:00:00],
          breaks: [{~T[10:00:00], ~T[10:30:00]}, {~T[12:00:00], ~T[13:00:00]}]
        )

      refute "10:00 AM" in slots
      refute "12:00 PM" in slots
      refute "12:30 PM" in slots
      assert "9:00 AM" in slots
      assert "10:30 AM" in slots
      assert "1:00 PM" in slots
    end

    test "handles slot that partially overlaps with break at start" do
      # Break from 10:15 to 10:45 - the 10:00 slot would end at 10:30, overlapping
      slots = day_labels(~T[09:00:00], ~T[12:00:00], breaks: [{~T[10:15:00], ~T[10:45:00]}])

      # 10:00 slot runs 10:00-10:30 which overlaps with break starting at 10:15
      refute "10:00 AM" in slots
      # 10:30 slot runs 10:30-11:00 which overlaps with break ending at 10:45
      refute "10:30 AM" in slots
    end
  end

  describe "slots across DST transitions" do
    # Europe/London falls back at 02:00 BST on 2026-10-25, so wall-clock
    # 01:00–01:59 happens twice. A break at 01:30 would crash DateTime.new!/3.
    test "resolves ambiguous break times on fall-back day without raising" do
      slots =
        day_labels(~T[09:00:00], ~T[12:00:00],
          date: ~D[2026-10-25],
          zone: "Europe/London",
          breaks: [{~T[01:30:00], ~T[01:45:00]}]
        )

      assert length(slots) == 6
      assert "9:00 AM" in slots
      assert "11:30 AM" in slots
    end

    # Europe/London springs forward at 01:00 GMT on 2026-03-29, so wall-clock
    # 01:00–01:59 never happens. A break at 01:30 would crash DateTime.new!/3.
    test "resolves break times in spring-forward gap without raising" do
      slots =
        day_labels(~T[09:00:00], ~T[12:00:00],
          date: ~D[2026-03-29],
          zone: "Europe/London",
          breaks: [{~T[01:30:00], ~T[01:45:00]}]
        )

      assert length(slots) == 6
      assert "9:00 AM" in slots
      assert "11:30 AM" in slots
    end

    # America/Santiago springs forward at 24:00 on 2026-09-05, so wall-clock
    # 00:00–00:59 never happens on 2026-09-06. The window opens on the 5th and
    # runs on into the booker's 6th, whose day therefore starts at 01:00.
    test "a booker's day that opens in a spring-forward gap starts when the gap ends" do
      slots =
        day_labels(~T[21:00:00], ~T[05:00:00],
          window_date: ~D[2026-09-05],
          date: ~D[2026-09-06],
          zone: "America/Santiago"
        )

      # The day starts at 01:00, not midnight; the gap is snapped forward.
      assert List.first(slots) == "1:00 AM"
      refute "12:00 AM" in slots
      assert length(slots) == 8
    end

    # America/Santiago falls back at 24:00 on 2026-04-04, so wall-clock
    # 23:00–23:59 happens twice and the end of the booker's day is ambiguous.
    # Spec rule: the slot that ends where the day ends is offered, so a window
    # running past midnight now lists 11:30 PM (the clamp used to drop it).
    test "a window running past midnight on a fall-back day offers the slot that ends at midnight" do
      slots =
        day_labels(~T[20:00:00], ~T[03:00:00],
          window_date: ~D[2026-04-04],
          zone: "America/Santiago"
        )

      assert List.first(slots) == "8:00 PM"
      assert List.last(slots) == "11:30 PM"
      assert length(slots) == 8
    end

    # A full day of availability over a midnight gap: the 6th starts at 01:00
    # and, with the window continuing past midnight, ends with the 11:30 PM
    # slot that the old per-day clamp dropped.
    test "a full day spanning a spring-forward gap runs from 1:00 AM to the slot ending at midnight" do
      config =
        pure_config(
          days: [
            %{
              day_of_week: 6,
              start_time: ~T[20:00:00],
              end_time: ~T[00:00:00],
              ends_next_day: true
            },
            %{
              day_of_week: 7,
              start_time: ~T[00:00:00],
              end_time: ~T[00:00:00],
              ends_next_day: true
            },
            %{day_of_week: 1, start_time: ~T[00:00:00], end_time: ~T[03:00:00]}
          ]
        )

      slots = labels(~D[2026-09-06], 30, "America/Santiago", "America/Santiago", config)

      assert List.first(slots) == "1:00 AM"
      assert List.last(slots) == "11:30 PM"
      assert length(slots) == 46
    end

    # Ambiguous breaks are still honoured at the first (earlier UTC) occurrence.
    test "ambiguous break still filters an overlapping slot" do
      # A break at wall-clock 10:30–11:00 is unambiguous and must still apply
      # — proves break resolution doesn't silently drop usable breaks.
      slots =
        day_labels(~T[09:00:00], ~T[12:00:00],
          date: ~D[2026-10-25],
          zone: "Europe/London",
          breaks: [{~T[10:30:00], ~T[11:00:00]}]
        )

      refute "10:30 AM" in slots
      assert "10:00 AM" in slots
      assert "11:00 AM" in slots
    end
  end

  describe "edge cases" do
    test "handles date mismatch - selected date before range" do
      # Window on Monday 16 June; the booker asks about Sunday 15 June.
      slots =
        day_labels(~T[09:00:00], ~T[12:00:00], window_date: ~D[2025-06-16], date: ~D[2025-06-15])

      assert slots == []
    end

    test "handles date mismatch - selected date after range" do
      # Window on Saturday 14 June; the booker asks about Sunday 15 June.
      slots =
        day_labels(~T[09:00:00], ~T[12:00:00], window_date: ~D[2025-06-14], date: ~D[2025-06-15])

      assert slots == []
    end

    test "handles range spanning from previous day" do
      # Range from late night June 14 to early morning June 15
      slots =
        day_labels(~T[22:00:00], ~T[02:00:00],
          window_date: ~D[2025-06-14],
          date: ~D[2025-06-15]
        )

      # Should only include slots from midnight to 2:00 AM on June 15
      assert slots == ["12:00 AM", "12:30 AM", "1:00 AM", "1:30 AM"]
      # Should NOT include slots from June 14
      refute "10:00 PM" in slots
    end

    # Spec rule: a start is listed on the booker's date it falls on, and the
    # whole meeting only has to fit inside available time. The old clamp to the
    # booker's day dropped 11:30 PM because it ends at midnight.
    test "a window running past midnight offers the slot that ends at midnight" do
      slots = day_labels(~T[22:00:00], ~T[02:00:00])

      assert slots == ["10:00 PM", "10:30 PM", "11:00 PM", "11:30 PM"]
    end

    test "a window running past midnight lists the rest of its slots on the next date" do
      slots =
        day_labels(~T[22:00:00], ~T[02:00:00],
          window_date: ~D[2025-06-15],
          date: ~D[2025-06-16]
        )

      assert slots == ["12:00 AM", "12:30 AM", "1:00 AM", "1:30 AM"]
    end
  end

  # The slots a schedule with one window offers a booker on the same clock as
  # the owner. The window opens on `:window_date` and `:date` is the booker's
  # date the labels are read for (both default to Sunday 15 June 2025, and the
  # zone to UTC). An end at or before the start runs into the next day.
  defp day_labels(start_time, end_time, opts \\ []) do
    window_date = Keyword.get(opts, :window_date, ~D[2025-06-15])
    date = Keyword.get(opts, :date, window_date)
    zone = Keyword.get(opts, :zone, "Etc/UTC")

    breaks =
      for {from, to} <- Keyword.get(opts, :breaks, []), do: %{start_time: from, end_time: to}

    config =
      pure_config(
        days: [
          %{
            day_of_week: Date.day_of_week(window_date),
            start_time: start_time,
            end_time: end_time,
            ends_next_day: Time.compare(end_time, start_time) != :gt,
            breaks: breaks
          }
        ],
        interval: Keyword.get(opts, :interval)
      )

    labels(date, Keyword.get(opts, :duration, 30), zone, zone, config)
  end

  describe "an explicit interval" do
    test "an interval shorter than the duration produces overlapping starts" do
      slots = interval_labels(~T[09:00:00], ~T[10:00:00], 30, 5)

      assert List.first(slots) == "9:00 AM"
      assert List.last(slots) == "9:30 AM"
      assert length(slots) == 7
      assert "9:05 AM" in slots
    end

    test "an interval longer than the duration produces fewer, rounder starts" do
      assert interval_labels(~T[09:00:00], ~T[10:00:00], 20, 60) == ["9:00 AM"]
    end

    test "an interval that does not divide the window is still bounded by it" do
      slots = interval_labels(~T[09:00:00], ~T[10:00:00], 30, 7)

      assert List.first(slots) == "9:00 AM"
      assert "9:07 AM" in slots
      # Last start must still leave room for the full 30-minute meeting.
      assert List.last(slots) == "9:28 AM"
    end

    test "a window shorter than the duration offers nothing regardless of interval" do
      assert interval_labels(~T[09:00:00], ~T[09:10:00], 30, 5) == []
    end

    test "a nil interval falls back to the duration" do
      with_nil = interval_labels(~T[09:00:00], ~T[10:00:00], 30, nil)

      assert with_nil == ["9:00 AM", "9:30 AM"]
      assert with_nil == interval_labels(~T[09:00:00], ~T[10:00:00], 30, 30)
    end

    test "an off-hour window with an interval that divides the hour aligns forward to the fix's target case" do
      slots = interval_labels(~T[09:15:00], ~T[17:00:00], 60, 60, "America/New_York")

      assert List.first(slots) == "10:00 AM"
      assert length(slots) == 7
    end

    # An interval that does NOT divide 60 (e.g. 120) aligns to the next whole
    # hour, not to multiples-of-itself-since-midnight. On an already-on-the-hour
    # window that alignment must be a no-op and 9:00 must still be offered —
    # this regressed once during development and was caught only by manual
    # measurement.
    test "an interval that does not divide 60 still offers the hour an on-the-hour window opens on" do
      slots = interval_labels(~T[09:00:00], ~T[17:00:00], 60, 120, "America/New_York")

      assert "9:00 AM" in slots
      assert slots == ["9:00 AM", "11:00 AM", "1:00 PM", "3:00 PM"]
    end

    test "alignment never offers a start before the window opens or too late for the duration to fit" do
      slots = interval_labels(~T[09:05:00], ~T[10:00:00], 30, 15)

      assert slots == ["9:15 AM", "9:30 AM"]

      earliest_legal_start = ~T[09:05:00]
      latest_legal_start = ~T[09:30:00]

      for slot <- slots do
        time = TimeSlots.parse_time_slot(slot)
        assert Time.compare(time, earliest_legal_start) != :lt
        assert Time.compare(time, latest_legal_start) != :gt
      end
    end

    test "breaks are filtered by the meeting's length, not by the interval" do
      slots =
        interval_labels(~T[09:00:00], ~T[10:00:00], 30, 5, "Europe/London",
          breaks: [{~T[09:20:00], ~T[09:30:00]}]
        )

      # A 30-minute meeting starting at 9:00 runs to 9:30 and so overlaps the
      # break; every start before the break ends is excluded.
      refute "9:00 AM" in slots
      assert "9:30 AM" in slots
    end

    test "an explicit interval equal to the duration reproduces the default grid exactly" do
      for duration <- [15, 20, 30, 45, 60],
          window_minutes <- [30, 60, 90, 125, 240] do
        end_time = Time.add(~T[09:00:00], window_minutes, :minute)

        generalised = interval_labels(~T[09:00:00], end_time, duration, duration)
        default = interval_labels(~T[09:00:00], end_time, duration, nil)

        assert generalised == default,
               "interval == duration must reproduce the default grid " <>
                 "(duration #{duration}, window #{window_minutes})"
      end
    end
  end

  describe "an explicit interval, across DST transitions" do
    # Europe/London falls back at 02:00 BST -> 01:00 GMT on 2026-10-25, so
    # wall-clock 01:00-01:59 happens twice. An interval whose grid walks
    # straight through that hour must resolve the repeat the same way plain
    # generation already does: collapse to a single, first-occurrence entry.
    test "resolves a repeated wall-clock hour the same way as generation without an interval" do
      slots =
        interval_labels(~T[00:45:00], ~T[03:00:00], 30, 15, "Europe/London", date: ~D[2026-10-25])

      assert slots == [
               "12:45 AM",
               "1:00 AM",
               "1:15 AM",
               "1:30 AM",
               "1:45 AM",
               "2:00 AM",
               "2:15 AM",
               "2:30 AM"
             ]

      assert Enum.count(slots, &(&1 == "1:00 AM")) == 1
    end

    # Europe/London springs forward at 01:00 GMT -> 02:00 BST on 2026-03-29,
    # so wall-clock 01:00-01:59 never happens. Aligning to a wall-clock
    # boundary that falls inside that gap must snap forward to the first real
    # instant, exactly as the un-intervalled DST tests above already pin for
    # break and boundary resolution.
    test "aligning into a spring-forward gap snaps forward to the first real instant" do
      slots =
        interval_labels(~T[00:45:00], ~T[03:00:00], 30, 20, "Europe/London", date: ~D[2026-03-29])

      assert slots == ["2:00 AM", "2:20 AM"]
      refute Enum.any?(slots, &String.starts_with?(&1, "1:"))
    end
  end

  # `day_labels/3` for the interval cases: the owner and the booker share a
  # clock, so the anchor cannot be what makes an assertion pass. The cases
  # where the two clocks differ live in
  # `Tymeslot.Availability.TimeSlotsOwnerAnchorTest`. Defaults to Monday
  # 15 June 2026 in Europe/London.
  defp interval_labels(
         start_time,
         end_time,
         duration,
         interval,
         zone \\ "Europe/London",
         opts \\ []
       ) do
    day_labels(
      start_time,
      end_time,
      window_date: Keyword.get(opts, :date, ~D[2026-06-15]),
      zone: zone,
      duration: duration,
      interval: interval,
      breaks: Keyword.get(opts, :breaks, [])
    )
  end
end
