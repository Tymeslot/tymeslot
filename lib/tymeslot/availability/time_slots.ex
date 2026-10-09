defmodule Tymeslot.Availability.TimeSlots do
  @moduledoc """
  Pure functions for generating a window's candidate slot starts and for
  formatting and parsing slot labels. Which candidates a booker's date
  actually offers is decided by `Tymeslot.Availability.SlotGrid`.
  """
  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  The grid of start instants for one window.

  Starts at the window's start, aligned to a wall-clock boundary on the
  owner's clock when an interval is set (see `align_to_interval/3`), and
  steps by the interval, or by the duration when there is none, while the
  start is before the window's end. Steps are elapsed time, so across a DST
  change the labels shift and the spacing does not.

  Whether a start is offered is decided elsewhere: one late in the window may
  still fit by running on into the next day's hours
  (`Tymeslot.Availability.SlotGrid`).

  A step that is not a positive number of minutes offers no starts.
  """
  @spec grid_starts(DateTime.t(), DateTime.t(), pos_integer(), pos_integer() | nil, String.t()) ::
          [DateTime.t()]
  def grid_starts(window_start, window_end, duration_minutes, interval_minutes, owner_timezone) do
    case interval_minutes || duration_minutes do
      step when is_integer(step) and step > 0 ->
        window_start
        |> align_to_interval(interval_minutes, owner_timezone)
        |> Stream.iterate(&DateTime.add(&1, step, :minute))
        |> Enum.take_while(&(DateTime.compare(&1, window_end) == :lt))

      # The changeset keeps intervals in range, but nothing below it does: a
      # step that never advances would walk forever, so it offers nothing.
      _not_a_step ->
        []
    end
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
  # `start_dt` may carry any zone, so the boundary is measured on the owner's
  # clock. That matters twice over. The offset between the booker's clock and
  # the owner's need not be a whole number of hours, so reading the booker's
  # clock would land the owner's
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
    # anchors on its own clock rather than failing the page outright.
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
end
