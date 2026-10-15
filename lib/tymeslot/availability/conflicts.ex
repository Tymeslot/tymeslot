defmodule Tymeslot.Availability.Conflicts do
  @moduledoc """
  Pure functions for conflict detection and slot filtering.

  Events must be pre-filtered through `CalendarEvent.blocking?/1` before
  reaching this module — it performs overlap checks only, not blocking logic.
  """

  alias Tymeslot.Availability.{Calculate, Reach, SlotGrid}
  alias Tymeslot.Utils.{DateTimeUtils, TimeRange}

  @typedoc """
  Configuration options controlling conflict detection and booking constraints.
  All keys are optional; sensible defaults are applied when absent.

  An alias of `Calculate.availability_config/0`, the canonical definition,
  rather than a second copy that can drift from it.
  """
  @type availability_config :: Calculate.availability_config()

  @doc """
  Filters candidate slot starts, as instants, by calendar conflicts and the
  booking rules: buffers, minimum notice, the booking window and booking
  limits.

  Events must already be filtered to blocking-only and converted to the user's
  timezone as maps with `start_time` / `end_time` (both `DateTime`).

  `config[:ignore_event_uids]`, when present, is a `MapSet` of event uids that
  must not block *their own* slot — i.e. an event is only disregarded for the
  one candidate slot whose start instant matches that event's start. Every
  other slot still sees it as blocking, so buffer protection around it is
  unaffected. This lets a live group meeting's own calendar event stop
  hiding the slot it occupies without losing its effect on neighbouring
  slots; see `Tymeslot.Availability.GroupSlots`.
  """
  @spec filter_available_starts(
          [DateTime.t()],
          [map()],
          pos_integer(),
          String.t(),
          Calculate.availability_config()
        ) :: [DateTime.t()]
  def filter_available_starts(starts, events, duration_minutes, timezone, config) do
    now = DateTimeUtils.now_in_timezone(timezone)
    Enum.filter(starts, &start_bookable?(&1, duration_minutes, now, events, config))
  end

  # Drops the blocking event that both carries an ignored uid and starts at
  # exactly this slot's instant — a slot can only shed "its own" event, never
  # another one sharing an ignored uid but a different start time.
  defp events_for_slot(events, slot_start, ignore_event_uids) do
    if MapSet.size(ignore_event_uids) == 0 do
      events
    else
      Enum.reject(events, &own_event_at?(&1, slot_start, ignore_event_uids))
    end
  end

  defp own_event_at?(event, slot_start, ignore_event_uids) do
    uid = Map.get(event, :uid)

    not is_nil(uid) and MapSet.member?(ignore_event_uids, uid) and
      DateTime.compare(event.start_time, slot_start) == :eq
  end

  # Booking limits are checked per slot (not per day) because the absolute
  # slot instant decides which host-timezone day/week/month it counts
  # against — one booker-timezone day can straddle two host days.
  #
  # A slot listed in `:limit_exempt_starts` is a live group slot with a seat
  # free: joining it adds no booking, so a cap it already counts towards must
  # not hide it (see `Tymeslot.Availability.GroupSlots`).
  defp limit_blocked?(%{limit_checker: checker} = config, slot_start)
       when is_function(checker, 1) do
    not MapSet.member?(
      Map.get(config, :limit_exempt_starts, MapSet.new()),
      DateTime.to_unix(slot_start)
    ) and checker.(slot_start)
  end

  defp limit_blocked?(_config, _slot_start), do: false

  @doc """
  Checks if a date has available slots given pre-fetched events.
  Used for efficient month view checking.

  Events must already be filtered to blocking-only and converted to the user's
  timezone as maps with `start_time` / `end_time` (both `DateTime`).

  Accepts a pre-computed `now` DateTime to avoid repeated clock calls
  when checking many dates in a loop.

  Reads the same starts as `Calculate.available_slots/6`, lazily
  (`SlotGrid.stream_for_date/5`), and stops at the first bookable one, so a `true` return is guaranteed to correspond to at least one slot the user
  can actually book.

  For best performance, `config` should also contain `:weekly_schedule`,
  `:overrides` and `:time_off` prefetched via
  `Calculate.prefetch_schedule_data/4`. Without them, per-date DB queries are
  issued for every owner date the date reads.

  The `events_in_user_tz` list is narrowed once per call to events whose
  date range overlaps `[target_date − 2, target_date + 2]`, avoiding a
  linear scan over the full multi-week list for every slot. That still covers
  every slot: a start on the date, a meeting of at most 24 hours, and at most
  two hours of buffer either side.
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
        config
      ) do
    duration_minutes =
      config |> Map.get(:duration_minutes, 30) |> max(1) |> min(Reach.max_meeting_minutes())

    nearby_events = events_near_date(events_in_user_tz, date)

    case SlotGrid.stream_for_date(date, duration_minutes, owner_timezone, user_timezone, config) do
      {:ok, starts} ->
        Enum.any?(starts, &start_bookable?(&1, duration_minutes, now, nearby_events, config))

      {:error, _reason} ->
        false
    end
  end

  # Narrows to events within ±2 days of target_date so the per-slot scan
  # inside `start_bookable?/5` does not traverse the full multi-week list.
  # Date comparison is used (rather than DateTime) to avoid constructing new
  # DateTimes with the user timezone, which can fail for unknown zones.
  defp events_near_date(events_in_user_tz, date) do
    date_lower = Date.add(date, -2)
    date_upper = Date.add(date, 2)

    Enum.filter(events_in_user_tz, fn event ->
      event_start_date = DateTime.to_date(event.start_time)
      event_end_date = DateTime.to_date(event.end_time)

      Date.compare(event_end_date, date_lower) != :lt and
        Date.compare(event_start_date, date_upper) != :gt
    end)
  end

  # The one rule both the day view and the month view apply to a start.
  defp start_bookable?(slot_start, duration_minutes, now, events, config) do
    %{
      buffer_before_minutes: buffer_before_minutes,
      buffer_after_minutes: buffer_after_minutes,
      min_advance_hours: min_advance_hours,
      max_advance_booking_days: max_advance_booking_days
    } = Calculate.config_policy(config)

    ignore_event_uids = Map.get(config, :ignore_event_uids, MapSet.new())
    slot_end = DateTime.add(slot_start, duration_minutes, :minute)

    TimeRange.meets_minimum_notice?(slot_start, now, min_advance_hours * 60) and
      TimeRange.within_booking_window?(slot_start, now, max_advance_booking_days) and
      not TimeRange.has_conflict_with_events?(
        slot_start,
        slot_end,
        events_for_slot(events, slot_start, ignore_event_uids),
        {buffer_before_minutes, buffer_after_minutes}
      ) and
      not limit_blocked?(config, slot_start)
  end
end
