defmodule Tymeslot.Availability.SlotGrid do
  @moduledoc """
  The times a schedule offers on one of the booker's dates, before calendar
  conflicts, buffers, notice, the booking window and booking limits.

  1. Read the owner dates that can matter: from the day before the owner date
     of the booker's midnight (yesterday's overnight tail) to the owner date
     of the latest instant a meeting starting that day can reach.
  2. Resolve each owner date's window to instants (`BusinessHours.owner_windows/4`).
  3. Available time is the union of the windows (touching ones joined) minus
     every break and every time-off period.
  4. Each window offers its own grid (`TimeSlots.grid_starts/5`), anchored at
     its own start exactly as before. A 24/7 schedule's joined stretch has no
     start to anchor to; a window always does.
  5. Keep the starts that fall on the booker's date, earliest first, one per
     label, and only those whose label resolves back to the same instant on
     that date: the booking path only ever receives the date and the label.
  6. Keep the starts whose whole meeting fits inside available time.

  For a same-day window that touches no other, this is exactly the grid the
  engine offered before overnight windows: same anchor, same steps, and
  "fits inside available time" is "inside the window, overlapping no break".
  """

  alias Tymeslot.Availability.{BusinessHours, Calculate, Intervals, TimeSlots}
  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  The starts offered on `date` (the booker's), as `DateTime`s in
  `user_timezone`, sorted. `{:error, reason}` when the booker's timezone
  cannot be read, so a caller can tell "nothing offered" from "could not tell".
  """
  @spec starts_for_date(
          Date.t(),
          pos_integer(),
          String.t(),
          String.t(),
          Calculate.availability_config()
        ) :: {:ok, [DateTime.t()]} | {:error, term()}
  def starts_for_date(date, duration_minutes, owner_timezone, user_timezone, config) do
    with {:ok, starts} <-
           stream_for_date(date, duration_minutes, owner_timezone, user_timezone, config) do
      {:ok, Enum.to_list(starts)}
    end
  end

  @doc """
  The same starts as `starts_for_date/5`, as a lazy enumerable in the same
  order, for a caller that only needs to know whether one of them passes a
  further test: the label, round-trip and fit checks then run only as far as
  the caller reads.
  """
  @spec stream_for_date(
          Date.t(),
          pos_integer(),
          String.t(),
          String.t(),
          Calculate.availability_config()
        ) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream_for_date(date, duration_minutes, owner_timezone, user_timezone, config) do
    with {:ok, day_start} <- DateTimeUtils.resolve_local(date, ~T[00:00:00], user_timezone),
         {:ok, next_day_start} <-
           DateTimeUtils.resolve_local(Date.add(date, 1), ~T[00:00:00], user_timezone) do
      schedule_id = Map.get(config, :schedule_id)
      reach = DateTime.add(next_day_start, duration_minutes, :minute)

      dates =
        Date.range(
          Date.add(owner_date(day_start, owner_timezone), -1),
          owner_date(reach, owner_timezone)
        )

      windows = BusinessHours.owner_windows(dates, schedule_id, owner_timezone, config)
      time_off = BusinessHours.time_off_intervals(dates, schedule_id, owner_timezone, config)
      free = available_time(windows, time_off)
      interval = Map.get(config, :slot_interval_minutes)

      starts =
        windows
        |> candidates({day_start, next_day_start}, duration_minutes, interval, owner_timezone)
        |> listed_on(date, user_timezone)
        |> Stream.filter(
          &Intervals.covers?(free, &1, DateTime.add(&1, duration_minutes, :minute))
        )

      {:ok, starts}
    end
  end

  defp available_time(windows, time_off) do
    windows
    |> Enum.map(&{&1.start_dt, &1.end_dt})
    |> Intervals.subtract(Enum.flat_map(windows, & &1.breaks) ++ time_off)
  end

  # Each window's grid starts that fall within the booker's day, as instants,
  # sorted. The day is `[day_start, next_day_start)`: the instants whose date
  # in the booker's zone is the booker's date, whatever DST does to either
  # midnight. A window's grid is still walked from its own start, so the
  # anchor is unchanged; it just stops at the end of the day.
  defp candidates(windows, {day_start, next_day_start} = day, duration_minutes, interval, tz) do
    windows
    |> Enum.filter(&overlaps?(&1, day))
    |> Enum.flat_map(fn window ->
      window.start_dt
      |> TimeSlots.grid_starts(
        earliest(window.end_dt, next_day_start),
        duration_minutes,
        interval,
        tz
      )
      |> Enum.drop_while(&(DateTime.compare(&1, day_start) == :lt))
    end)
    |> Enum.sort(DateTime)
  end

  defp overlaps?(%{start_dt: start_dt, end_dt: end_dt}, {day_start, next_day_start}),
    do:
      DateTime.compare(end_dt, day_start) == :gt and
        DateTime.compare(start_dt, next_day_start) == :lt

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  # Sorted first, so the label de-duplication keeps the earlier of two
  # occurrences of a repeated fall-back hour, as the engine always has.
  defp listed_on(sorted_starts, date, user_timezone) do
    sorted_starts
    |> Stream.map(&DateTime.shift_zone!(&1, user_timezone))
    |> Stream.uniq_by(&TimeSlots.format_datetime_slot/1)
    |> Stream.filter(&round_trips?(&1, date, user_timezone))
  end

  defp round_trips?(start, date, user_timezone) do
    case DateTimeUtils.resolve_local(date, DateTime.to_time(start), user_timezone) do
      {:ok, resolved} -> DateTime.compare(resolved, start) == :eq
      {:error, _reason} -> false
    end
  end

  # An unreadable owner zone falls back to UTC, as window resolution does.
  defp owner_date(instant, owner_timezone) do
    case DateTime.shift_zone(instant, owner_timezone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _reason} -> instant |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()
    end
  end
end
