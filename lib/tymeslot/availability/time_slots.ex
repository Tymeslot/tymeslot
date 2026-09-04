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
  Resolves a day's breaks into absolute instants on the owner's clock.

  Break times are stored as the owner's local wall-clock times with no date
  attached, so they mean nothing until anchored to a date and a zone. Both
  have to be the *owner's*: the window a slot grid is built from has already
  been shifted into the booker's zone, and resolving a break there puts the
  owner's lunch on the booker's clock, hiding the wrong hours by exactly the
  offset between them.

  `owner_date` must be the owner-frame date the breaks were read for
  (`window.date`), not the date of the window's start in the booker's zone.
  A window can straddle midnight in the booker's zone, which is why windows
  carry the date they came from; taking the date off the booker-side datetime
  reintroduces the same error one day out instead of one offset out.

  Resolving against a real date and zone, rather than applying a fixed offset,
  is also what keeps this correct across a DST boundary inside the window.
  """
  @spec resolve_breaks([{Time.t(), Time.t()}], Date.t(), String.t()) ::
          [{DateTime.t(), DateTime.t()}]
  def resolve_breaks(breaks, owner_date, owner_timezone)
      when is_list(breaks) and is_binary(owner_timezone) do
    Enum.map(breaks, fn {break_start_time, break_end_time} ->
      {resolve_wall_time(owner_date, break_start_time, owner_timezone),
       resolve_wall_time(owner_date, break_end_time, owner_timezone)}
    end)
  end

  @doc """
  Generates time slots for a date range, excluding break periods, on the
  historical duration-locked grid.

  Equivalent to `generate_slots_for_range_with_breaks/7` with no interval and
  no anchor, and kept as its own arity because the duration-locked grid needs
  neither.

  Breaks are absolute instants; see `resolve_breaks/3`.
  """
  @spec generate_slots_for_range_with_breaks(
          DateTime.t(),
          DateTime.t(),
          integer(),
          Date.t(),
          [{DateTime.t(), DateTime.t()}]
        ) :: [String.t()]
  def generate_slots_for_range_with_breaks(
        start_dt,
        end_dt,
        duration_minutes,
        selected_date,
        breaks
      ) do
    generate_slots_for_range_with_breaks(
      start_dt,
      end_dt,
      duration_minutes,
      selected_date,
      breaks,
      nil,
      nil
    )
  end

  @doc """
  Generates time slots for a date range, excluding break periods.

  ## Parameters
    - start_dt: Start datetime
    - end_dt: End datetime
    - duration_minutes: Meeting duration in minutes
    - selected_date: The date for slot generation
    - breaks: Break periods as absolute `{start, end}` instants, already
      resolved against the owner's date and zone by `resolve_breaks/3`.
      They must arrive resolved: `start_dt` here is in the *booker's* zone,
      so a break carried as a bare `Time` would be read on the booker's wall
      clock and land on the wrong hours whenever the two zones differ.
    - breaks: List of {start_time, end_time} tuples representing break periods
    - interval_minutes: Optional spacing between slot starts. Defaults to the
      meeting duration, which is the historical behaviour. A shorter interval
      offers overlapping starts; a longer one offers fewer, rounder starts.
      When set explicitly, the grid also anchors to a wall-clock boundary
      (e.g. 60 minutes lands on the hour) instead of wherever the window
      happens to start; a nil interval keeps the unanchored, duration-locked
      grid unchanged.
    - owner_timezone: The clock that anchoring reads. `start_dt` has already
      been shifted into the booker's timezone by the time it gets here, so
      the boundary has to be measured somewhere else: the interval is the
      owner's setting and means "this far apart, on my clock". Required
      whenever `interval_minutes` is set, ignored when it is nil.

  Returns a list of formatted time strings like "9:00 AM", excluding slots that
  would overlap with break periods.
  """
  @spec generate_slots_for_range_with_breaks(
          DateTime.t(),
          DateTime.t(),
          integer(),
          Date.t(),
          [{DateTime.t(), DateTime.t()}],
          pos_integer() | nil,
          String.t() | nil
        ) :: [String.t()]
  def generate_slots_for_range_with_breaks(
        start_dt,
        end_dt,
        duration_minutes,
        selected_date,
        breaks,
        interval_minutes,
        owner_timezone
      ) do
    start_date = DateTime.to_date(start_dt)
    end_date = DateTime.to_date(end_dt)

    slot_range = determine_slot_range(start_date, end_date, selected_date, start_dt, end_dt)

    # Generate all possible slots first
    all_slots =
      generate_slots_for_determined_range(
        slot_range,
        duration_minutes,
        interval_minutes,
        owner_timezone
      )

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
        midnight = resolve_wall_time(selected_date, ~T[00:00:00], start_dt.time_zone)
        {midnight, end_dt}

      {:eq, :gt} ->
        # Availability spans to next day (e.g., early morning hours)
        end_of_day = resolve_wall_time(selected_date, ~T[23:59:59], start_dt.time_zone)
        {start_dt, end_of_day}

      {:lt, :gt} ->
        # Full day availability (extreme timezone difference)
        midnight = resolve_wall_time(selected_date, ~T[00:00:00], start_dt.time_zone)
        end_of_day = resolve_wall_time(selected_date, ~T[23:59:59], start_dt.time_zone)
        {midnight, end_of_day}

      _other ->
        # No slots for this date
        :no_slots
    end
  end

  defp generate_slots_for_determined_range(
         :no_slots,
         _duration_minutes,
         _interval_minutes,
         _owner_timezone
       ),
       do: []

  defp generate_slots_for_determined_range(
         {start_dt, end_dt},
         duration_minutes,
         interval_minutes,
         owner_timezone
       ) do
    generate_slots_for_single_day(
      start_dt,
      end_dt,
      duration_minutes,
      interval_minutes,
      owner_timezone
    )
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

  defp generate_slots_for_single_day(
         start_dt,
         end_dt,
         duration_minutes,
         interval_minutes,
         owner_timezone
       ) do
    # Only an explicit interval anchors the grid to a wall-clock boundary
    # (e.g. 60 minutes lands on the hour), and the clock it lands on is the
    # owner's, not the booker's: the interval is the owner's setting, so a
    # 60-minute grid has to sit on the hour in the owner's calendar whoever is
    # looking at it. A nil interval keeps the historical duration-locked anchor
    # at `start_dt` exactly, so meeting types that have never set an interval
    # see no change at all.
    grid_start = align_to_interval(start_dt, interval_minutes, owner_timezone)
    total_minutes = DateTime.diff(end_dt, grid_start, :minute)
    # A slot's length is always the duration; the interval only moves its start.
    # Falling back to the duration makes this a strict generalisation of the
    # duration-locked grid this replaced.
    interval = interval_minutes || duration_minutes

    if total_minutes < duration_minutes do
      []
    else
      # The last legal start is the one that still leaves room for the full
      # meeting, so the count is measured over `total - duration`, not `total`.
      # With interval == duration this is exactly div(total, duration).
      slot_count = div(total_minutes - duration_minutes, interval) + 1

      # Iteration walks forward in UTC. On a DST fall-back day the wall-clock
      # hour repeats, producing two DateTime structs with different offsets but
      # the same formatted label. Users can't disambiguate "1:00 AM EDT" from
      # "1:00 AM EST" when booking, so collapse duplicates to the earlier
      # occurrence.
      0..(slot_count - 1)
      |> Enum.map(fn i ->
        slot_datetime = DateTime.add(grid_start, i * interval, :minute)
        format_datetime_slot(slot_datetime)
      end)
      |> Enum.uniq()
    end
  end

  # Rounds `start_dt` forward to the next boundary on the owner's wall clock,
  # never earlier than `start_dt`, so a slot is never offered before the
  # window opens.
  #
  # An interval that divides the hour (5, 10, 15, 20, 30, 60) aligns to its
  # own multiples since owner-local midnight, e.g. 15 minutes lands on the
  # quarter-hour. An interval that does NOT divide the hour (45, 90, 120, or
  # anything else that isn't a divisor of 60) aligns to the next whole hour
  # instead and steps by the interval from there: anchoring those to
  # multiples-of-the-interval-since-midnight would silently reinterpret
  # "every 2 hours" as "only on even hours" and discard availability the
  # owner's window actually offers (a 09:00-17:00 window with a 120-minute
  # interval must still offer 09:00, not just 10:00/12:00/...).
  #
  # `start_dt` carries the booker's wall clock by this point, because
  # business-hours windows are shifted into the booker's timezone before slot
  # generation, so the boundary is measured on the owner's clock instead. That
  # matters twice over. The offset between the two clocks need not be a whole
  # number of hours, so reading the booker's clock would land the owner's
  # 09:00 on a :30 or :45 boundary of their own; and rounding only ever moves
  # forward, so it would also discard the owner's first partial slot. The
  # booker sees a start such as 12:30 rather than 13:00, which is simply what
  # the owner's 09:00 looks like on their clock.
  #
  # The distance to the boundary is measured on the owner's clock and then
  # applied as elapsed time, which keeps the result at or after `start_dt`
  # through a DST transition in either zone. A nil interval is the
  # duration-locked default, not an explicit choice, so it is left completely
  # alone and never reads the owner's clock at all.
  defp align_to_interval(start_dt, nil, _owner_timezone), do: start_dt

  defp align_to_interval(start_dt, interval_minutes, owner_timezone)
       when is_binary(owner_timezone) do
    # An unresolvable timezone falls back to `start_dt` unchanged, which
    # anchors on the booker's clock rather than failing the page outright.
    owner_dt = DateTimeUtils.convert_to_timezone(start_dt, owner_timezone)

    boundary = if rem(60, interval_minutes) == 0, do: interval_minutes, else: 60
    minutes_since_midnight = owner_dt.hour * 60 + owner_dt.minute
    remainder = rem(minutes_since_midnight, boundary)

    if remainder == 0 do
      start_dt
    else
      DateTime.add(start_dt, boundary - remainder, :minute)
    end
  end

  defp filter_slots_by_breaks(slots, [], _start_dt, _duration_minutes), do: slots

  # Slots are resolved on the booker's clock, which is where they are offered;
  # breaks arrive already absolute, resolved on the owner's. Both sides are
  # instants by the time they meet, so the comparison holds across any offset.
  defp filter_slots_by_breaks(slots, breaks, start_dt, duration_minutes) do
    date = DateTime.to_date(start_dt)
    timezone = start_dt.time_zone

    Enum.filter(slots, fn slot ->
      slot_time = parse_time_slot(slot)
      slot_start_dt = resolve_wall_time(date, slot_time, timezone)
      slot_end_dt = DateTime.add(slot_start_dt, duration_minutes, :minute)

      not Enum.any?(breaks, fn {break_start_dt, break_end_dt} ->
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
