defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series.Shift do
  @moduledoc """
  Moving the date and date-time properties of a recurring event by a fixed
  amount, each in the form it is written in.

  When every occurrence of a series moves, `ICalBuilder.Series.edit_master/5`
  moves each line that names a slot of it (the master's `DTSTART` and
  `DTEND`, its `EXDATE`s and `RDATE`s, every override's `RECURRENCE-ID` and
  timing) by the same amount. A line keeps the form the server wrote it in,
  because an `EXDATE` or a `RECURRENCE-ID` only matches a slot in the value
  type and zone of the master's `DTSTART` (RFC 5545 §3.8.5.1, §3.8.4.4):

    * a wall clock (`TZID`, or floating) moves on the wall clock, so a series
      moved from 10:00 to 11:00 in Berlin reads 11:00 on both sides of a DST
      change;
    * a UTC value (`...Z`) moves as an instant;
    * a date moves by whole days, and a shift that is not whole days is
      `{:error, :shift_not_whole_days}`.

  Amounts are seconds on the wall clock of the series' zone: the difference
  between two wall-clock readings (`wall/3`), not between two instants, so a
  move of "one hour later" stays one hour on the clock whichever DST side it
  lands on.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Document
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Timing
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.Duration

  @day 86_400

  # What the sync's parser assumes when an event states neither DTEND nor
  # DURATION, so an edit compares like with like.
  @default_timed_duration 3_600

  @value ~r/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/i

  @typedoc "A value as read: a date, or a wall clock with its UTC marker."
  @type value :: {:date, Date.t()} | {:date_time, NaiveDateTime.t(), utc? :: boolean()}

  @doc """
  Moves every value of the property `line` by `seconds`, in its own form.
  A list value (`EXDATE:a,b`) moves each of its members.

  Returns `{:error, :shift_not_whole_days}` for a date moved by part of a
  day, and `{:error, :unsupported_value}` for a value that is neither a date
  nor a date-time (an `RDATE` period).
  """
  @spec shift_line(String.t(), integer()) ::
          {:ok, String.t()} | {:error, :shift_not_whole_days | :unsupported_value}
  def shift_line(line, 0), do: {:ok, line}

  def shift_line(line, seconds) when is_integer(seconds) do
    {name_and_params, values} = ContentLines.split_value(line)

    with {:ok, shifted} <- Document.map_ok(String.split(values, ","), &shift_value(&1, seconds)) do
      {:ok, name_and_params <> ":" <> Enum.join(shifted, ",")}
    end
  end

  @doc """
  Reads the first value of the timing property `line` as a wall clock in
  `series_zone` (UTC when `nil`), a date as its midnight. The line's own zone
  is resolved as `ICalBuilder.Timing.zone/2` resolves it, with `fallback` for
  a `TZID` no time zone database knows. `:error` for a value it cannot read.
  """
  @spec wall(String.t(), String.t() | nil, String.t() | nil) :: {:ok, NaiveDateTime.t()} | :error
  def wall(line, series_zone, fallback) do
    {_name_and_params, values} = ContentLines.split_value(line)

    case read(values |> String.split(",") |> hd()) do
      {:ok, {:date, date}} ->
        {:ok, NaiveDateTime.new!(date, ~T[00:00:00])}

      {:ok, {:date_time, naive, utc?}} ->
        own_zone = if utc?, do: "Etc/UTC", else: Timing.zone(line, fallback) || series_zone
        in_zone(naive, own_zone, series_zone)

      :error ->
        :error
    end
  end

  @doc """
  `datetime` (a UTC instant) as a wall clock in `series_zone`, UTC when
  `nil`; a `Date` as its midnight.
  """
  @spec wall_of(Date.t() | DateTime.t(), String.t() | nil) :: {:ok, NaiveDateTime.t()} | :error
  def wall_of(%Date{} = date, _series_zone), do: {:ok, NaiveDateTime.new!(date, ~T[00:00:00])}

  def wall_of(%DateTime{} = datetime, series_zone) do
    case DateTime.shift_zone(datetime, series_zone || "Etc/UTC") do
      {:ok, local} -> {:ok, DateTime.to_naive(local)}
      {:error, _reason} -> :error
    end
  end

  @doc """
  An occurrence key (`YYYYMMDDTHHMMSS`, or `YYYYMMDD` all-day), which is
  already a wall clock in the series' zone, as one.
  """
  @spec key_wall(String.t()) :: {:ok, NaiveDateTime.t()} | :error
  def key_wall(key) do
    case read(key) do
      {:ok, {:date, date}} -> {:ok, NaiveDateTime.new!(date, ~T[00:00:00])}
      {:ok, {:date_time, naive, false}} -> {:ok, naive}
      _unreadable -> :error
    end
  end

  @doc """
  How long the `VEVENT` whose property lines are `properties` lasts on the
  series' wall clock, in seconds: from `DTSTART` to `DTEND`, or its
  `DURATION`, or the sync parser's default (an hour, or a day for a date)
  when it states neither.
  """
  @spec duration([String.t()], String.t() | nil, String.t() | nil) :: {:ok, integer()} | :error
  def duration(properties, series_zone, fallback) do
    start = ContentLines.find("DTSTART", properties)
    finish = ContentLines.find("DTEND", properties)
    stated = ContentLines.find("DURATION", properties)

    cond do
      is_nil(start) -> :error
      finish -> between(start, finish, series_zone, fallback)
      stated -> {:ok, stated_duration(stated, Timing.date?(start))}
      Timing.date?(start) -> {:ok, @day}
      true -> {:ok, @default_timed_duration}
    end
  end

  defp between(start, finish, series_zone, fallback) do
    with {:ok, from} <- wall(start, series_zone, fallback),
         {:ok, to} <- wall(finish, series_zone, fallback) do
      {:ok, NaiveDateTime.diff(to, from)}
    end
  end

  defp stated_duration(line, date?) do
    {_name, value} = ContentLines.split_value(line)

    case Duration.parse(String.trim(value)) do
      {:ok, seconds} -> seconds
      {:error, _reason} -> if date?, do: @day, else: @default_timed_duration
    end
  end

  defp in_zone(naive, zone, zone), do: {:ok, naive}

  defp in_zone(naive, own_zone, series_zone) do
    with {:ok, instant} <-
           DateTimeUtils.resolve_local(
             NaiveDateTime.to_date(naive),
             NaiveDateTime.to_time(naive),
             own_zone || "Etc/UTC"
           ),
         {:ok, local} <- DateTime.shift_zone(instant, series_zone || "Etc/UTC") do
      {:ok, DateTime.to_naive(local)}
    else
      _unknown_zone -> :error
    end
  end

  defp shift_value(value, seconds) do
    case read(value) do
      {:ok, {:date, date}} when rem(seconds, @day) == 0 ->
        {:ok, Format.format_date(Date.add(date, div(seconds, @day)))}

      {:ok, {:date, _date}} ->
        {:error, :shift_not_whole_days}

      {:ok, {:date_time, naive, utc?}} ->
        stamp = naive |> NaiveDateTime.add(seconds) |> Format.format_naive_datetime()
        {:ok, if(utc?, do: stamp <> "Z", else: stamp)}

      :error ->
        {:error, :unsupported_value}
    end
  end

  @spec read(String.t()) :: {:ok, value()} | :error
  defp read(value) do
    case Regex.run(@value, String.trim(value)) do
      [_all, y, m, d] -> read_date(y, m, d)
      [_all, y, m, d, hh, mm, ss, utc] -> read_date_time([y, m, d, hh, mm, ss], utc != "")
      nil -> :error
    end
  end

  defp read_date(y, m, d) do
    case Date.new(int(y), int(m), int(d)) do
      {:ok, date} -> {:ok, {:date, date}}
      {:error, _reason} -> :error
    end
  end

  defp read_date_time([y, m, d, hh, mm, ss], utc?) do
    case NaiveDateTime.new(int(y), int(m), int(d), int(hh), int(mm), int(ss)) do
      {:ok, naive} -> {:ok, {:date_time, naive, utc?}}
      {:error, _reason} -> :error
    end
  end

  defp int(digits), do: String.to_integer(digits)
end
