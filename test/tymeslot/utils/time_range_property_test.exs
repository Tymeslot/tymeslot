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

  # A bookable-looking slot: 15 minutes to two hours long.
  defp slot_gen do
    gen all(start_dt <- datetime_gen(), length <- integer(15..120)) do
      {start_dt, DateTime.add(start_dt, length, :minute)}
    end
  end

  # Busy events within six hours either side of `anchor`, so a good share of
  # them land inside or next to a slot's buffers rather than months away.
  defp nearby_events_gen(anchor) do
    event =
      gen all(offset <- integer(-360..360), length <- integer(1..180)) do
        start_time = DateTime.add(anchor, offset, :minute)
        %{start_time: start_time, end_time: DateTime.add(start_time, length, :minute)}
      end

    list_of(event, max_length: 4)
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

  describe "add_buffer/4" do
    property "moves the start earlier by the first amount and the end later by the second" do
      check all(
              {start_dt, end_dt} <- ordered_datetime_pair_gen(),
              buffer_before <- integer(0..120),
              buffer_after <- integer(0..120)
            ) do
        {padded_start, padded_end} =
          TimeRange.add_buffer(start_dt, end_dt, buffer_before, buffer_after)

        assert DateTime.diff(start_dt, padded_start, :second) == buffer_before * 60
        assert DateTime.diff(padded_end, end_dt, :second) == buffer_after * 60
      end
    end

    property "zero buffers return the original range" do
      check all({start_dt, end_dt} <- ordered_datetime_pair_gen()) do
        assert TimeRange.add_buffer(start_dt, end_dt, 0, 0) == {start_dt, end_dt}
      end
    end
  end

  describe "has_conflict_with_events?/4" do
    # The oracles below never pad the candidate. Padding the candidate by
    # `before` and `after` is the same, per event, as padding the event by
    # `after` in front and `before` behind, so they check the rule from the
    # other side instead of restating the implementation.

    property "a slot conflicts iff [start - before, end + after] overlaps an event" do
      check all(
              {slot_start, slot_end} <- slot_gen(),
              events <- nearby_events_gen(slot_start),
              buffer_before <- integer(0..120),
              buffer_after <- integer(0..120)
            ) do
        expected =
          Enum.any?(events, fn event ->
            TimeRange.overlaps?(
              slot_start,
              slot_end,
              DateTime.add(event.start_time, -buffer_after, :minute),
              DateTime.add(event.end_time, buffer_before, :minute)
            )
          end)

        assert TimeRange.has_conflict_with_events?(
                 slot_start,
                 slot_end,
                 events,
                 {buffer_before, buffer_after}
               ) == expected
      end
    end

    property "an event after the slot blocks it only through the after-buffer" do
      check all(
              {slot_start, slot_end} <- slot_gen(),
              gap <- integer(0..180),
              buffer_before <- integer(0..120),
              buffer_after <- integer(0..120)
            ) do
        event_start = DateTime.add(slot_end, gap, :minute)
        event = %{start_time: event_start, end_time: DateTime.add(event_start, 30, :minute)}

        assert TimeRange.has_conflict_with_events?(
                 slot_start,
                 slot_end,
                 [event],
                 {buffer_before, buffer_after}
               ) == gap < buffer_after
      end
    end

    property "an event before the slot blocks it only through the before-buffer" do
      check all(
              {slot_start, slot_end} <- slot_gen(),
              gap <- integer(0..180),
              buffer_before <- integer(0..120),
              buffer_after <- integer(0..120)
            ) do
        event_end = DateTime.add(slot_start, -gap, :minute)
        event = %{start_time: DateTime.add(event_end, -30, :minute), end_time: event_end}

        assert TimeRange.has_conflict_with_events?(
                 slot_start,
                 slot_end,
                 [event],
                 {buffer_before, buffer_after}
               ) == gap < buffer_before
      end
    end

    # The migration copies each schedule's old buffer into both new ones and
    # promises that no offered slot changes. That holds only if an equal pair
    # blocks exactly what padding every event by that amount used to.
    property "equal buffers block exactly what the old symmetric rule blocked" do
      check all(
              {slot_start, slot_end} <- slot_gen(),
              events <- nearby_events_gen(slot_start),
              buffer <- integer(0..120)
            ) do
        old_rule =
          Enum.any?(events, fn event ->
            TimeRange.overlaps?(
              slot_start,
              slot_end,
              DateTime.add(event.start_time, -buffer, :minute),
              DateTime.add(event.end_time, buffer, :minute)
            )
          end)

        assert TimeRange.has_conflict_with_events?(
                 slot_start,
                 slot_end,
                 events,
                 {buffer, buffer}
               ) == old_rule
      end
    end
  end

  describe "duration_minutes/2" do
    property "recovers the number of minutes the end time was moved by" do
      # The expected value comes from constructing the range, not from calling
      # `DateTime.diff/3` a second time: an implementation that measured in
      # seconds, or that swapped its arguments, would agree with itself.
      check all(
              start_dt <- datetime_gen(),
              minutes <- integer(0..10_080)
            ) do
        end_dt = DateTime.add(start_dt, minutes, :minute)

        assert TimeRange.duration_minutes(start_dt, end_dt) == minutes
      end
    end

    property "counts a range backwards as negative minutes" do
      check all(
              start_dt <- datetime_gen(),
              minutes <- integer(1..10_080)
            ) do
        earlier = DateTime.add(start_dt, -minutes, :minute)

        assert TimeRange.duration_minutes(start_dt, earlier) == -minutes
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
