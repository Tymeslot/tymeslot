defmodule Tymeslot.Availability.GapLogicTest do
  @moduledoc """
  Tests covering specific event/slot-grid alignment scenarios in
  `Conflicts.date_has_slots_with_events?/6`.

  The boolean fast-path enumerates the same discrete slot grid as
  `Calculate.available_slots/6`, so a slot only "fits" when there is an
  actual slot on the grid that survives the buffer/conflict check —
  reasoning about continuous-time gap widths is not sufficient. The
  bidirectional equivalence property is asserted in
  `Tymeslot.Availability.ConflictsTest`.
  """
  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.Conflicts
  alias Tymeslot.Utils.DateTimeUtils

  describe "slot-grid alignment cases" do
    setup do
      %{
        date: get_safe_test_date(),
        timezone: "UTC",
        duration: 30,
        buffer: 10
      }
    end

    test "returns true when an aligned slot fits in the gap between two events", %{
      date: date,
      timezone: timezone,
      duration: duration,
      buffer: buffer
    } do
      # Business hours 11:00–19:30, duration 30, buffer 10.
      # Slot grid: 11:00, 11:30, 12:00, …
      # Event 1 ends at 11:50 (= slot_start 12:00 − buffer 10)
      # Event 2 starts at 12:40 (= slot_end 12:30 + buffer 10)
      # → slot 12:00–12:30 fits exactly on the grid.
      events = [
        build_event(date, timezone, ~T[08:00:00], ~T[11:50:00]),
        build_event(date, timezone, ~T[12:40:00], ~T[14:00:00]),
        build_event(date, timezone, ~T[14:00:00], ~T[20:00:00])
      ]

      assert call_date_has_slots(date, timezone, events, buffer, duration)
    end

    test "returns false when the gap is one minute too small for any aligned slot", %{
      date: date,
      timezone: timezone,
      duration: duration,
      buffer: buffer
    } do
      # Same shape as above but event 2 starts at 12:39, so the buffer
      # encroaches on the 12:00 slot and no other grid position fits.
      events = [
        build_event(date, timezone, ~T[08:00:00], ~T[11:50:00]),
        build_event(date, timezone, ~T[12:39:00], ~T[14:00:00]),
        build_event(date, timezone, ~T[14:00:00], ~T[20:00:00])
      ]

      refute call_date_has_slots(date, timezone, events, buffer, duration)
    end

    test "returns false when a continuous-time gap exists but no aligned slot fits", %{
      date: date,
      timezone: timezone,
      duration: duration,
      buffer: buffer
    } do
      # Regression for the month-view false-availability bug: a 50-minute
      # gap between 12:00 and 12:50 is large enough for a 30-min slot in
      # continuous time, but the slot grid lands on :00/:30 with business
      # starting at 11:00, so no slot actually fits.
      events = [
        build_event(date, timezone, ~T[08:00:00], ~T[12:00:00]),
        build_event(date, timezone, ~T[12:50:00], ~T[14:00:00]),
        build_event(date, timezone, ~T[14:00:00], ~T[20:00:00])
      ]

      refute call_date_has_slots(date, timezone, events, buffer, duration)
    end

    test "returns true when a 30-minute gap exists between overlapping events", %{
      date: date,
      timezone: timezone,
      duration: duration
    } do
      # Events 1–3 cover 00:00–14:00 (events 2 and 3 overlap each other).
      # Event 4 covers 14:30–15:00; event 5 covers 15:00–23:59:59.
      # The open window 14:00–14:30 is exactly 30 minutes with buffer=0,
      # and the slot grid (business hours 11:00, step 30 min) lands the
      # 14:00 slot squarely in that gap → at least one bookable slot exists.
      events = [
        build_event(date, timezone, ~T[00:00:00], ~T[12:00:00]),
        build_event(date, timezone, ~T[12:00:00], ~T[13:00:00]),
        build_event(date, timezone, ~T[12:30:00], ~T[14:00:00]),
        build_event(date, timezone, ~T[14:30:00], ~T[15:00:00]),
        build_event(date, timezone, ~T[15:00:00], ~T[23:59:59])
      ]

      assert call_date_has_slots(date, timezone, events, 0, duration)
    end
  end

  defp build_event(date, timezone, start_time, end_time) do
    %{
      start_time: DateTime.new!(date, start_time, timezone),
      end_time: DateTime.new!(date, end_time, timezone)
    }
  end

  defp call_date_has_slots(date, timezone, events, buffer, duration) do
    Conflicts.date_has_slots_with_events?(
      date,
      timezone,
      timezone,
      events,
      DateTimeUtils.now_in_timezone(timezone),
      %{buffer_minutes: buffer, duration_minutes: duration, min_advance_hours: 0}
    )
  end

  defp get_safe_test_date do
    Date.utc_today()
    |> Date.add(30)
    |> then(fn date ->
      days_to_monday = 1 - Date.day_of_week(date)
      days_to_monday = if days_to_monday <= 0, do: days_to_monday + 7, else: days_to_monday
      Date.add(date, days_to_monday)
    end)
  end
end
