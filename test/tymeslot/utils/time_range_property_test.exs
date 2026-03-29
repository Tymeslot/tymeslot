defmodule Tymeslot.Utils.TimeRangePropertyTest do
  @moduledoc """
  Property-based tests for TimeRange utility functions.
  """
  use ExUnit.Case, async: true
  @moduletag :utils
  use ExUnitProperties

  alias Tymeslot.Utils.TimeRange

  # -- Generators --

  defp datetime_gen do
    gen all(
          days_offset <- integer(0..365),
          hour <- integer(0..23),
          minute <- integer(0..59),
          second <- integer(0..59)
        ) do
      DateTime.add(
        ~U[2025-01-01 00:00:00Z],
        days_offset * 86_400 + hour * 3600 + minute * 60 + second,
        :second
      )
    end
  end

  defp ordered_datetime_pair_gen do
    gen all(
          dt1 <- datetime_gen(),
          gap_seconds <- integer(1..86_400)
        ) do
      dt2 = DateTime.add(dt1, gap_seconds, :second)
      {dt1, dt2}
    end
  end

  # -- Properties --

  describe "overlaps?/4" do
    property "is symmetric" do
      check all(
              {s1, e1} <- ordered_datetime_pair_gen(),
              {s2, e2} <- ordered_datetime_pair_gen()
            ) do
        assert TimeRange.overlaps?(s1, e1, s2, e2) == TimeRange.overlaps?(s2, e2, s1, e1)
      end
    end

    property "a range always overlaps with itself" do
      check all({start_dt, end_dt} <- ordered_datetime_pair_gen()) do
        assert TimeRange.overlaps?(start_dt, end_dt, start_dt, end_dt)
      end
    end

    property "non-overlapping ranges: A entirely before B" do
      check all(
              {s1, e1} <- ordered_datetime_pair_gen(),
              gap <- integer(0..3600)
            ) do
        s2 = DateTime.add(e1, gap, :second)
        e2 = DateTime.add(s2, 3600, :second)

        refute TimeRange.overlaps?(s1, e1, s2, e2)
      end
    end

    property "contained range always overlaps" do
      check all(
              {outer_start, outer_end} <- ordered_datetime_pair_gen(),
              shrink_start <- integer(0..30),
              shrink_end <- integer(0..30)
            ) do
        gap = DateTime.diff(outer_end, outer_start, :second)

        if gap > shrink_start + shrink_end + 1 do
          inner_start = DateTime.add(outer_start, shrink_start, :second)
          inner_end = DateTime.add(outer_end, -shrink_end, :second)

          assert TimeRange.overlaps?(outer_start, outer_end, inner_start, inner_end)
        end
      end
    end
  end

  describe "add_buffer/3" do
    property "expands the range (start moves earlier, end moves later)" do
      check all(
              {start_dt, end_dt} <- ordered_datetime_pair_gen(),
              buffer <- integer(0..120)
            ) do
        {buffered_start, buffered_end} = TimeRange.add_buffer(start_dt, end_dt, buffer)

        assert DateTime.compare(buffered_start, start_dt) != :gt
        assert DateTime.compare(buffered_end, end_dt) != :lt
      end
    end

    property "zero buffer returns the original range" do
      check all({start_dt, end_dt} <- ordered_datetime_pair_gen()) do
        assert TimeRange.add_buffer(start_dt, end_dt, 0) == {start_dt, end_dt}
      end
    end

    property "buffer expansion is exact" do
      check all(
              {start_dt, end_dt} <- ordered_datetime_pair_gen(),
              buffer <- integer(1..120)
            ) do
        {buffered_start, buffered_end} = TimeRange.add_buffer(start_dt, end_dt, buffer)

        assert DateTime.diff(start_dt, buffered_start, :second) == buffer * 60
        assert DateTime.diff(buffered_end, end_dt, :second) == buffer * 60
      end
    end
  end

  describe "duration_minutes/2" do
    property "matches DateTime.diff in minutes" do
      check all({start_dt, end_dt} <- ordered_datetime_pair_gen()) do
        assert TimeRange.duration_minutes(start_dt, end_dt) ==
                 DateTime.diff(end_dt, start_dt, :minute)
      end
    end

    property "is non-negative for ordered pairs" do
      check all({start_dt, end_dt} <- ordered_datetime_pair_gen()) do
        assert TimeRange.duration_minutes(start_dt, end_dt) >= 0
      end
    end
  end

  describe "within_booking_window?/3" do
    property "slots in the past are never within the window" do
      check all(
              past_offset <- integer(1..365),
              max_days <- integer(1..90)
            ) do
        now = DateTime.utc_now()
        past_slot = DateTime.add(now, -past_offset * 86_400, :second)

        refute TimeRange.within_booking_window?(past_slot, now, max_days)
      end
    end

    property "slots beyond max_days are never within the window" do
      check all(
              extra_days <- integer(1..100),
              max_days <- integer(1..90)
            ) do
        now = DateTime.utc_now()
        far_slot = DateTime.add(now, (max_days + extra_days) * 86_400, :second)

        refute TimeRange.within_booking_window?(far_slot, now, max_days)
      end
    end
  end

  describe "meets_minimum_notice?/3" do
    property "slots far enough in the future always meet notice" do
      check all(
              notice_minutes <- integer(0..1440),
              extra_minutes <- integer(1..1440)
            ) do
        now = DateTime.utc_now()
        slot = DateTime.add(now, (notice_minutes + extra_minutes) * 60, :second)

        assert TimeRange.meets_minimum_notice?(slot, now, notice_minutes)
      end
    end

    property "slots too soon never meet notice" do
      check all(
              notice_minutes <- integer(2..1440),
              deficit_minutes <- integer(1..1440)
            ) do
        now = DateTime.utc_now()
        too_soon_minutes = max(notice_minutes - deficit_minutes, 0)

        if too_soon_minutes < notice_minutes do
          slot = DateTime.add(now, too_soon_minutes * 60, :second)
          refute TimeRange.meets_minimum_notice?(slot, now, notice_minutes)
        end
      end
    end

    property "zero notice means any future slot is valid" do
      check all(future_minutes <- integer(1..10_000)) do
        now = DateTime.utc_now()
        slot = DateTime.add(now, future_minutes * 60, :second)

        assert TimeRange.meets_minimum_notice?(slot, now, 0)
      end
    end
  end
end
