defmodule Tymeslot.Availability.Conflicts do
  @moduledoc """
  Pure functions for conflict detection and slot filtering.
  """

  alias Tymeslot.Availability.{BusinessHours, Events, TimeSlots}
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
          optional(:profile_id) => integer() | nil,
          optional(atom()) => term()
        }

  @doc """
  Filters available slots based on conflicts and booking rules.
  """
  @spec filter_available_slots(
          [String.t()],
          [Events.converted_event()],
          integer(),
          String.t(),
          Date.t(),
          availability_config()
        ) :: [String.t()]
  def filter_available_slots(all_slots, events, duration_minutes, timezone, date, config \\ %{}) do
    buffer_minutes = Map.get(config, :buffer_minutes, 15)
    min_advance_hours = Map.get(config, :min_advance_hours, 3)
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)

    current_time = DateTimeUtils.now_in_timezone(timezone)

    busy = busy_events(events)

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
        not TimeRange.has_conflict_with_events?(slot_start, slot_end, busy, buffer_minutes)
    end)
  end

  defp meets_booking_constraints?(slot_start, current_time, min_advance_hours, max_advance_days) do
    TimeRange.meets_minimum_notice?(slot_start, current_time, min_advance_hours * 60) and
      TimeRange.within_booking_window?(slot_start, current_time, max_advance_days)
  end

  @doc """
  Checks if a date has available slots given pre-fetched events.
  Used for efficient month view checking.

  Accepts a pre-computed `now` DateTime to avoid repeated clock calls
  when checking many dates in a loop.
  """
  @spec date_has_slots_with_events?(
          Date.t(),
          String.t(),
          String.t(),
          [Events.converted_event()],
          DateTime.t(),
          availability_config()
        ) :: boolean()
  def date_has_slots_with_events?(
        date,
        owner_timezone,
        user_timezone,
        events_in_user_tz,
        now,
        config \\ %{}
      ) do
    buffer_minutes = Map.get(config, :buffer_minutes, 15)
    min_advance_hours = Map.get(config, :min_advance_hours, 3)
    duration_minutes = Map.get(config, :duration_minutes, 30)
    profile_id = Map.get(config, :profile_id)

    minimum_booking_time = DateTime.add(now, min_advance_hours * 60, :minute)
    relevant_events = events_in_user_tz |> busy_events() |> filter_events_for_date_window(date)

    params = %{
      target_date: date,
      profile_id: profile_id,
      owner_tz: owner_timezone,
      user_tz: user_timezone,
      min_booking_time: minimum_booking_time,
      events: relevant_events,
      buffer: buffer_minutes,
      duration_minutes: duration_minutes,
      config: config
    }

    Enum.any?([Date.add(date, -1), date, Date.add(date, 1)], fn d ->
      check_day_for_slots(d, params)
    end)
  end

  defp filter_events_for_date_window(events, date) do
    start_date_limit = Date.add(date, -2)
    end_date_limit = Date.add(date, 2)

    Enum.filter(events, fn event ->
      case {event.start_time, event.end_time} do
        {%DateTime{} = s, %DateTime{} = e} ->
          event_start_date = DateTime.to_date(s)
          event_end_date = DateTime.to_date(e)

          not (Date.compare(event_end_date, start_date_limit) == :lt or
                 Date.compare(event_start_date, end_date_limit) == :gt)

        _other ->
          false
      end
    end)
  end

  defp check_day_for_slots(d, params) do
    {start_time, end_time} =
      BusinessHours.business_hours_range(params.profile_id, Date.day_of_week(d), params.config)

    if is_nil(start_time) or is_nil(end_time) do
      false
    else
      owner_start = DateTimeUtils.create_datetime_safe(d, start_time, params.owner_tz)
      owner_end = DateTimeUtils.create_datetime_safe(d, end_time, params.owner_tz)

      case {DateTime.shift_zone(owner_start, params.user_tz),
            DateTime.shift_zone(owner_end, params.user_tz)} do
        {{:ok, user_start}, {:ok, user_end}} ->
          if DateTime.to_date(user_start) == params.target_date or
               DateTime.to_date(user_end) == params.target_date do
            check_window_availability(user_start, user_end, params)
          else
            false
          end

        _other ->
          false
      end
    end
  end

  defp check_window_availability(user_start, user_end, params) do
    target_start =
      DateTimeUtils.create_datetime_safe(params.target_date, ~T[00:00:00], params.user_tz)

    target_end =
      DateTimeUtils.create_datetime_safe(params.target_date, ~T[23:59:59.999999], params.user_tz)

    start_bound = Enum.max([user_start, target_start, params.min_booking_time], DateTime)

    latest_start_allowed_by_business = DateTime.add(user_end, -params.duration_minutes, :minute)
    latest_start = Enum.min([target_end, latest_start_allowed_by_business], DateTime)

    if DateTime.compare(start_bound, latest_start) == :gt do
      false
    else
      check_gaps_with_events(start_bound, user_end, latest_start, params)
    end
  end

  defp check_gaps_with_events(start_bound, user_end, latest_start, params) do
    relevant_events =
      params.events
      |> Enum.filter(fn event ->
        DateTime.compare(event.end_time, start_bound) == :gt and
          DateTime.compare(event.start_time, user_end) == :lt
      end)
      |> Enum.sort_by(& &1.start_time, DateTime)

    if Enum.empty?(relevant_events) do
      true
    else
      check_relevant_event_gaps(relevant_events, start_bound, latest_start, params)
    end
  end

  defp check_relevant_event_gaps(relevant_events, start_bound, latest_start, params) do
    first_event = List.first(relevant_events)

    if DateTime.diff(first_event.start_time, start_bound) >=
         (params.duration_minutes + params.buffer) * 60 do
      true
    else
      {last_end, found_gap} = find_gap_between_events(relevant_events, latest_start, params)

      if found_gap do
        true
      else
        gap_start = DateTime.add(last_end, params.buffer, :minute)
        DateTime.compare(gap_start, latest_start) != :gt
      end
    end
  end

  defp find_gap_between_events(relevant_events, latest_start, params) do
    Enum.reduce_while(relevant_events, {nil, false}, fn event, {prev_end, _value} ->
      if is_nil(prev_end) do
        {:cont, {event.end_time, false}}
      else
        gap_start = DateTime.add(prev_end, params.buffer, :minute)
        gap_end = DateTime.add(event.start_time, -params.buffer, :minute)

        latest_t_in_gap =
          Enum.min(
            [latest_start, DateTime.add(gap_end, -params.duration_minutes, :minute)],
            DateTime
          )

        if DateTime.compare(gap_start, latest_t_in_gap) != :gt do
          {:halt, {event.end_time, true}}
        else
          new_end = Enum.max([prev_end, event.end_time], DateTime)
          {:cont, {new_end, false}}
        end
      end
    end)
  end

  # All providers normalise free events to transparency: "transparent".
  defp busy_events(events) do
    Enum.reject(events, fn event ->
      Map.get(event, :transparency) == "transparent"
    end)
  end
end
