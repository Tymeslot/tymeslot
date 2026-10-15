defmodule Tymeslot.Test.LegacySlotEngine do
  @moduledoc """
  A frozen copy of the schedule-only slot engine as it stood before overnight
  windows: `BusinessHours.windows_for_target_date_or_error/5`,
  `TimeSlots.generate_slots_for_range_with_breaks/7` (with its clamp to the
  booker's day at 00:00 and 23:59:59), weekly breaks, overrides and time off.
  No calendar events, notice, booking window or limits.

  It exists to pin the promise that existing schedules keep their offered
  slots. **Never edit it to make a test pass.** When behaviour is meant to
  change, the property that compares against it narrows its scope instead,
  and the narrowing is justified in that test.

  Reads only the in-memory config built by `Tymeslot.Test.SlotGridHelpers`.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @end_of_day ~T[23:59:59]

  @doc "The labels today's engine offers on `date` for the booker."
  @spec slots(Date.t(), pos_integer(), String.t(), String.t(), map()) :: [String.t()]
  def slots(date, duration, owner_tz, user_tz, config) do
    date |> labelled(duration, owner_tz, user_tz, config) |> labels()
  end

  @doc """
  Like `slots/5`, keeping only labels whose generated instant is the instant
  `resolve_local/3` gives the label on `date`. The new engine guarantees this
  for every label it lists; the legacy one did not in a fall-back hour.
  """
  @spec round_trip_slots(Date.t(), pos_integer(), String.t(), String.t(), map()) :: [String.t()]
  def round_trip_slots(date, duration, owner_tz, user_tz, config) do
    date
    |> labelled(duration, owner_tz, user_tz, config)
    |> Enum.filter(fn {label, instant} ->
      {:ok, resolved} = DateTimeUtils.resolve_local(date, parse(label), user_tz)
      DateTime.compare(resolved, instant) == :eq
    end)
    |> labels()
  end

  @doc """
  Whether any window the legacy engine reads for `date` starts and ends on
  different dates in the booker's zone, i.e. whether the booker's midnight
  cuts a window. The spec promises no change only where this is false.
  """
  @spec cuts_window?(Date.t(), String.t(), String.t(), map()) :: boolean()
  def cuts_window?(date, owner_tz, user_tz, config) do
    date
    |> windows(owner_tz, user_tz, config)
    |> Enum.any?(&(DateTime.to_date(&1.start_dt) != DateTime.to_date(&1.end_dt)))
  end

  defp labels(pairs),
    do: pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort_by(&parse/1, Time)

  defp labelled(date, duration, owner_tz, user_tz, config) do
    interval = Map.get(config, :slot_interval_minutes)

    date
    |> windows(owner_tz, user_tz, config)
    |> Enum.flat_map(fn window ->
      breaks = resolve_breaks(breaks_for_day(window.date, config), window.date, owner_tz)
      generate(window.start_dt, window.end_dt, duration, date, breaks, interval, owner_tz)
    end)
  end

  # --- BusinessHours, as it was ---

  defp windows(target_date, owner_tz, user_tz, config) do
    Enum.flat_map([Date.add(target_date, -1), target_date, Date.add(target_date, 1)], fn d ->
      case business_hours(d, owner_tz, user_tz, config) do
        {start_dt, end_dt} ->
          if DateTime.to_date(start_dt) == target_date or DateTime.to_date(end_dt) == target_date,
            do: [%{start_dt: start_dt, end_dt: end_dt, date: d}],
            else: []

        nil ->
          []
      end
    end)
  end

  defp business_hours(date, owner_tz, user_tz, config) do
    if all_day_off?(config.time_off, date) do
      nil
    else
      case day_opening(date, config) do
        {start_time, end_time} ->
          owner_start = DateTimeUtils.create_datetime_safe(date, start_time, owner_tz)
          owner_end = DateTimeUtils.create_datetime_safe(date, end_time, owner_tz)
          {DateTime.shift_zone!(owner_start, user_tz), DateTime.shift_zone!(owner_end, user_tz)}

        _closed ->
          nil
      end
    end
  end

  defp day_opening(date, config) do
    case Enum.find(config.overrides, &(&1.date == date)) do
      %{override_type: "unavailable"} ->
        :closed

      %{override_type: type, start_time: %Time{} = s, end_time: %Time{} = e}
      when type in ["custom_hours", "available"] ->
        {s, e}

      %{override_type: type} when type in ["custom_hours", "available"] ->
        weekly_opening(date, config, :no_hours)

      _none ->
        weekly_opening(date, config, :closed)
    end
  end

  defp weekly_opening(date, config, closed_when_absent) do
    case Enum.find(config.weekly_schedule, &(&1.day_of_week == Date.day_of_week(date))) do
      %{is_available: true, start_time: %Time{} = s, end_time: %Time{} = e} -> {s, e}
      %{is_available: true} -> :no_hours
      _other -> closed_when_absent
    end
  end

  defp breaks_for_day(date, config) do
    weekly =
      case Enum.find(config.weekly_schedule, &(&1.day_of_week == Date.day_of_week(date))) do
        %{breaks: breaks} when is_list(breaks) -> Enum.map(breaks, &{&1.start_time, &1.end_time})
        _other -> []
      end

    weekly ++ time_off_windows(config.time_off, date)
  end

  # --- TimeOff, as it was ---

  defp all_day_off?(periods, date),
    do: Enum.any?(periods, &(blocked_window(&1, date) == :all_day))

  defp time_off_windows(periods, date) do
    Enum.flat_map(periods, fn period ->
      case blocked_window(period, date) do
        {from, to} -> [{from, to}]
        _other -> []
      end
    end)
  end

  defp blocked_window(%{starts_on: starts_on, ends_on: ends_on} = period, date) do
    if Date.compare(date, starts_on) == :lt or Date.compare(date, ends_on) == :gt do
      :none
    else
      from = if date == starts_on, do: period[:start_time] || ~T[00:00:00], else: ~T[00:00:00]
      to = if date == ends_on, do: period[:end_time] || @end_of_day, else: @end_of_day

      cond do
        Time.compare(from, to) != :lt -> :none
        from == ~T[00:00:00] and to == @end_of_day -> :all_day
        true -> {from, to}
      end
    end
  end

  # --- TimeSlots, as it was ---

  defp resolve_breaks(breaks, owner_date, owner_tz) do
    Enum.map(breaks, fn {s, e} ->
      {DateTimeUtils.create_datetime_safe(owner_date, s, owner_tz),
       DateTimeUtils.create_datetime_safe(owner_date, e, owner_tz)}
    end)
  end

  defp generate(start_dt, end_dt, duration, selected_date, breaks, interval, owner_tz) do
    case range(
           DateTime.to_date(start_dt),
           DateTime.to_date(end_dt),
           selected_date,
           start_dt,
           end_dt
         ) do
      :no_slots ->
        []

      {range_start, range_end} ->
        range_start
        |> single_day(range_end, duration, interval, owner_tz)
        |> Enum.reject(&in_break?(&1, breaks, range_start, duration))
    end
  end

  defp range(start_date, end_date, selected_date, start_dt, end_dt) do
    case {Date.compare(start_date, selected_date), Date.compare(end_date, selected_date)} do
      {:eq, :eq} -> {start_dt, end_dt}
      {:lt, :eq} -> {midnight(selected_date, start_dt), end_dt}
      {:eq, :gt} -> {start_dt, end_of_day(selected_date, start_dt)}
      {:lt, :gt} -> {midnight(selected_date, start_dt), end_of_day(selected_date, start_dt)}
      _other -> :no_slots
    end
  end

  defp midnight(date, dt),
    do: DateTimeUtils.create_datetime_safe(date, ~T[00:00:00], dt.time_zone)

  defp end_of_day(date, dt),
    do: DateTimeUtils.create_datetime_safe(date, @end_of_day, dt.time_zone)

  # Returns `{label, instant}` pairs, deduplicated by label keeping the first,
  # exactly as `generate_slots_for_single_day/5` deduplicated its labels.
  defp single_day(start_dt, end_dt, duration, interval, owner_tz) do
    grid_start = align(start_dt, interval, owner_tz)
    total = DateTime.diff(end_dt, grid_start, :minute)
    step = interval || duration

    if total < duration do
      []
    else
      0..div(total - duration, step)
      |> Enum.map(fn i ->
        instant = DateTime.add(grid_start, i * step, :minute)
        {format(instant), instant}
      end)
      |> Enum.uniq_by(&elem(&1, 0))
    end
  end

  defp align(start_dt, nil, _owner_tz), do: start_dt

  defp align(start_dt, interval, owner_tz) do
    owner_dt = DateTimeUtils.convert_to_timezone(start_dt, owner_tz)
    boundary = if rem(60, interval) == 0, do: interval, else: 60
    remainder = rem(owner_dt.hour * 60 + owner_dt.minute, boundary)
    if remainder == 0, do: start_dt, else: DateTime.add(start_dt, boundary - remainder, :minute)
  end

  defp in_break?(_slot, [], _range_start, _duration), do: false

  defp in_break?({label, _instant}, breaks, range_start, duration) do
    slot_start =
      DateTimeUtils.create_datetime_safe(
        DateTime.to_date(range_start),
        parse(label),
        range_start.time_zone
      )

    slot_end = DateTime.add(slot_start, duration, :minute)

    Enum.any?(breaks, fn {bs, be} ->
      DateTime.compare(slot_start, be) == :lt and DateTime.compare(slot_end, bs) == :gt
    end)
  end

  defp format(dt) do
    minute = dt.minute |> Integer.to_string() |> String.pad_leading(2, "0")

    cond do
      dt.hour == 0 -> "12:#{minute} AM"
      dt.hour < 12 -> "#{dt.hour}:#{minute} AM"
      dt.hour == 12 -> "12:#{minute} PM"
      true -> "#{dt.hour - 12}:#{minute} PM"
    end
  end

  defp parse(label) do
    {:ok, time} = DateTimeUtils.parse_time_string(label)
    time
  end
end
