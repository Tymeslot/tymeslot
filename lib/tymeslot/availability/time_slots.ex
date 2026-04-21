defmodule Tymeslot.Availability.TimeSlots do
  @moduledoc """
  Pure functions for time slot generation and formatting.
  """
  alias Tymeslot.Utils.{DateTimeUtils, TimeRange}

  @doc """
  Generates time slots for a date range, handling timezone boundaries.

  Returns a list of formatted time strings like "9:00 AM".
  """
  @spec generate_slots_for_range(DateTime.t(), DateTime.t(), integer(), Date.t()) ::
          list(String.t())
  def generate_slots_for_range(start_dt, end_dt, duration_minutes, selected_date) do
    generate_slots_for_range_with_breaks(start_dt, end_dt, duration_minutes, selected_date, [])
  end

  @doc """
  Generates time slots for a date range, excluding break periods.

  ## Parameters
    - start_dt: Start datetime
    - end_dt: End datetime
    - duration_minutes: Meeting duration in minutes
    - selected_date: The date for slot generation
    - breaks: List of {start_time, end_time} tuples representing break periods

  Returns a list of formatted time strings like "9:00 AM", excluding slots that
  would overlap with break periods.
  """
  @spec generate_slots_for_range_with_breaks(DateTime.t(), DateTime.t(), integer(), Date.t(), [
          {Time.t(), Time.t()}
        ]) :: [String.t()]
  def generate_slots_for_range_with_breaks(
        start_dt,
        end_dt,
        duration_minutes,
        selected_date,
        breaks
      ) do
    start_date = DateTime.to_date(start_dt)
    end_date = DateTime.to_date(end_dt)

    slot_range = determine_slot_range(start_date, end_date, selected_date, start_dt, end_dt)

    # Generate all possible slots first
    all_slots = generate_slots_for_determined_range(slot_range, duration_minutes)

    # Filter out slots that overlap with breaks
    case slot_range do
      {range_start, _range_end} ->
        filter_slots_by_breaks(all_slots, breaks, range_start, duration_minutes)

      :no_slots ->
        []
    end
  end

  defp determine_slot_range(start_date, end_date, selected_date, start_dt, end_dt) do
    case {Date.compare(start_date, selected_date), Date.compare(end_date, selected_date)} do
      {:eq, :eq} ->
        # Normal case: availability is on the same day
        {start_dt, end_dt}

      {:lt, :eq} ->
        # Availability spans from previous day (e.g., late night hours)
        midnight = DateTime.new!(selected_date, ~T[00:00:00], start_dt.time_zone)
        {midnight, end_dt}

      {:eq, :gt} ->
        # Availability spans to next day (e.g., early morning hours)
        end_of_day = DateTime.new!(selected_date, ~T[23:59:59], start_dt.time_zone)
        {start_dt, end_of_day}

      {:lt, :gt} ->
        # Full day availability (extreme timezone difference)
        midnight = DateTime.new!(selected_date, ~T[00:00:00], start_dt.time_zone)
        end_of_day = DateTime.new!(selected_date, ~T[23:59:59], start_dt.time_zone)
        {midnight, end_of_day}

      _other ->
        # No slots for this date
        :no_slots
    end
  end

  defp generate_slots_for_determined_range(:no_slots, _duration_minutes), do: []

  defp generate_slots_for_determined_range({start_dt, end_dt}, duration_minutes) do
    generate_slots_for_single_day(start_dt, end_dt, duration_minutes)
  end

  @doc """
  Formats a datetime as a time slot string (e.g., "9:00 AM").
  """
  @spec format_datetime_slot(DateTime.t()) :: String.t()
  def format_datetime_slot(datetime) do
    hour = datetime.hour

    minute =
      if datetime.minute == 0, do: "00", else: String.pad_leading("#{datetime.minute}", 2, "0")

    cond do
      hour == 0 -> "12:#{minute} AM"
      hour < 12 -> "#{hour}:#{minute} AM"
      hour == 12 -> "12:#{minute} PM"
      true -> "#{hour - 12}:#{minute} PM"
    end
  end

  @doc """
  Parses a time slot string (e.g., "9:00 AM") into a Time struct.
  """
  @spec parse_time_slot(String.t()) :: Time.t()
  def parse_time_slot(slot_string) do
    case DateTimeUtils.parse_time_string(slot_string) do
      {:ok, time} -> time
      {:error, _reason} -> raise ArgumentError, "Invalid time slot: #{inspect(slot_string)}"
    end
  end

  @doc """
  Parses a duration string into minutes.
  """
  @spec parse_duration(String.t()) :: integer()
  def parse_duration(duration) when is_integer(duration), do: duration

  def parse_duration(duration) when is_binary(duration) do
    case Regex.run(~r/^\s*(\d+)\s*(?:-?\s*min(?:utes?)?)?\s*$/i, duration) do
      [_first, minutes_str] ->
        case Integer.parse(minutes_str) do
          {minutes, ""} when minutes > 0 -> minutes
          _other -> 30
        end

      _other ->
        30
    end
  end

  # Private functions

  defp generate_slots_for_single_day(start_dt, end_dt, duration_minutes) do
    total_minutes = DateTime.diff(end_dt, start_dt, :minute)

    if total_minutes < duration_minutes do
      []
    else
      slot_count = div(total_minutes, duration_minutes)

      # Iteration walks forward in UTC. On a DST fall-back day the wall-clock
      # hour repeats, producing two DateTime structs with different offsets but
      # the same formatted label. Users can't disambiguate "1:00 AM EDT" from
      # "1:00 AM EST" when booking, so collapse duplicates to the earlier
      # occurrence.
      0..(slot_count - 1)
      |> Enum.map(fn i ->
        slot_datetime = DateTime.add(start_dt, i * duration_minutes, :minute)
        format_datetime_slot(slot_datetime)
      end)
      |> Enum.uniq()
    end
  end

  defp filter_slots_by_breaks(slots, [], _start_dt, _duration_minutes), do: slots

  defp filter_slots_by_breaks(slots, breaks, start_dt, duration_minutes) do
    date = DateTime.to_date(start_dt)
    timezone = start_dt.time_zone

    resolved_breaks =
      Enum.map(breaks, fn {break_start_time, break_end_time} ->
        {resolve_wall_time(date, break_start_time, timezone),
         resolve_wall_time(date, break_end_time, timezone)}
      end)

    Enum.filter(slots, fn slot ->
      slot_time = parse_time_slot(slot)
      slot_start_dt = resolve_wall_time(date, slot_time, timezone)
      slot_end_dt = DateTime.add(slot_start_dt, duration_minutes, :minute)

      not Enum.any?(resolved_breaks, fn {break_start_dt, break_end_dt} ->
        TimeRange.overlaps?(slot_start_dt, slot_end_dt, break_start_dt, break_end_dt)
      end)
    end)
  end

  # DST wall-clock resolution: fall-back anchors to the first occurrence;
  # spring-forward snaps forward past the gap.
  defp resolve_wall_time(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, dt} -> dt
      {:ambiguous, first, _second} -> first
      {:gap, _before, just_after} -> just_after
    end
  end
end
