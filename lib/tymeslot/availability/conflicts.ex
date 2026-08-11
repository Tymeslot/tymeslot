defmodule Tymeslot.Availability.Conflicts do
  @moduledoc """
  Pure functions for conflict detection and slot filtering.

  Events must be pre-filtered through `CalendarEvent.blocking?/1` before
  reaching this module — it performs overlap checks only, not blocking logic.
  """

  alias Tymeslot.Availability.{BusinessHours, TimeSlots}
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Utils.{DateTimeUtils, TimeRange}

  @typedoc """
  Configuration options controlling conflict detection and booking constraints.
  All keys are optional; sensible defaults are applied when absent.
  """
  @type availability_config :: %{
          optional(:buffer_minutes) => non_neg_integer(),
          optional(:min_advance_hours) => non_neg_integer(),
          optional(:max_advance_booking_days) => pos_integer(),
          optional(:duration_minutes) => pos_integer(),
          optional(:schedule_id) => integer() | nil,
          optional(:limit_checker) => (DateTime.t() -> boolean()) | nil,
          optional(atom()) => term()
        }

  @doc """
  Filters available slots based on conflicts and booking rules.

  Events must already be filtered to blocking-only and converted to the user's
  timezone as maps with `start_time` / `end_time` (both `DateTime`).
  """
  @spec filter_available_slots(
          [String.t()],
          [map()],
          integer(),
          String.t(),
          Date.t(),
          Calculate.availability_config()
        ) :: [String.t()]
  def filter_available_slots(all_slots, events, duration_minutes, timezone, date, config \\ %{}) do
    buffer_minutes = Map.get(config, :buffer_minutes, 15)
    min_advance_hours = Map.get(config, :min_advance_hours, 3)
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)

    current_time = DateTimeUtils.now_in_timezone(timezone)

    Enum.filter(all_slots, fn slot ->
      slot_time = TimeSlots.parse_time_slot(slot)
      slot_start = DateTimeUtils.create_datetime_safe(date, slot_time, timezone)
      slot_end = DateTime.add(slot_start, duration_minutes, :minute)

      meets_booking_constraints?(
        slot_start,
        current_time,
        min_advance_hours,
        max_advance_booking_days
      ) and
        not TimeRange.has_conflict_with_events?(slot_start, slot_end, events, buffer_minutes) and
        not limit_blocked?(config, slot_start)
    end)
  end

  # Booking limits are checked per slot (not per day) because the absolute
  # slot instant decides which host-timezone day/week/month it counts
  # against — one booker-timezone day can straddle two host days.
  defp limit_blocked?(%{limit_checker: checker}, slot_start) when is_function(checker, 1) do
    checker.(slot_start)
  end

  defp limit_blocked?(_config, _slot_start), do: false

  defp meets_booking_constraints?(slot_start, current_time, min_advance_hours, max_advance_days) do
    TimeRange.meets_minimum_notice?(slot_start, current_time, min_advance_hours * 60) and
      TimeRange.within_booking_window?(slot_start, current_time, max_advance_days)
  end

  @doc """
  Checks if a date has available slots given pre-fetched events.
  Used for efficient month view checking.

  Events must already be filtered to blocking-only and converted to the user's
  timezone as maps with `start_time` / `end_time` (both `DateTime`).

  Accepts a pre-computed `now` DateTime to avoid repeated clock calls
  when checking many dates in a loop.

  Enumerates the same discrete slot grid as `available_slots/6` and
  short-circuits on the first available slot, so a `true` return is guaranteed
  to correspond to at least one slot the user can actually book.

  For best performance, `config` should also contain `:weekly_schedule` and
  `:overrides` prefetched via `Calculate.prefetch_schedule_data/4`. Without
  them, per-date DB queries are issued for each adjacent-day check.

  The `events_in_user_tz` list is narrowed once per call to events whose
  date range overlaps `[target_date − 2, target_date + 2]`, avoiding a
  linear scan over the full multi-week list for every slot.
  """
  @spec date_has_slots_with_events?(
          Date.t(),
          String.t(),
          String.t(),
          [map()],
          DateTime.t(),
          Calculate.availability_config()
        ) :: boolean()
  def date_has_slots_with_events?(
        date,
        owner_timezone,
        user_timezone,
        events_in_user_tz,
        now,
        config \\ %{}
      ) do
    duration_minutes = config |> Map.get(:duration_minutes, 30) |> max(1) |> min(1440)
    buffer_minutes = Map.get(config, :buffer_minutes, 15)
    min_advance_hours = Map.get(config, :min_advance_hours, 3)
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)
    schedule_id = Map.get(config, :schedule_id)

    # Pre-filter to events within ±2 days of target_date so the inner
    # per-slot Enum.any? scan does not traverse the full multi-week list.
    # Date comparison is used (rather than DateTime) to avoid constructing
    # new DateTimes with the user timezone, which can fail for unknown zones.
    date_lower = Date.add(date, -2)
    date_upper = Date.add(date, 2)

    nearby_events =
      Enum.filter(events_in_user_tz, fn event ->
        event_start_date = DateTime.to_date(event.start_time)
        event_end_date = DateTime.to_date(event.end_time)

        Date.compare(event_end_date, date_lower) != :lt and
          Date.compare(event_start_date, date_upper) != :gt
      end)

    business_hours_windows =
      BusinessHours.windows_for_target_date(
        date,
        schedule_id,
        owner_timezone,
        user_timezone,
        config
      )

    Enum.any?(business_hours_windows, fn window ->
      breaks = BusinessHours.breaks_for_day(window.date, schedule_id, config)

      slots =
        TimeSlots.generate_slots_for_range_with_breaks(
          window.start_dt,
          window.end_dt,
          duration_minutes,
          date,
          breaks
        )

      Enum.any?(slots, fn slot ->
        slot_time = TimeSlots.parse_time_slot(slot)
        slot_start = DateTimeUtils.create_datetime_safe(date, slot_time, user_timezone)
        slot_end = DateTime.add(slot_start, duration_minutes, :minute)

        TimeRange.meets_minimum_notice?(slot_start, now, min_advance_hours * 60) and
          TimeRange.within_booking_window?(slot_start, now, max_advance_booking_days) and
          not TimeRange.has_conflict_with_events?(
            slot_start,
            slot_end,
            nearby_events,
            buffer_minutes
          ) and
          not limit_blocked?(config, slot_start)
      end)
    end)
  end
end
