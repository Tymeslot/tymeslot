defmodule Tymeslot.BookingSeries.Dates do
  @moduledoc """
  The starts of a recurring series, expanded from its first.

  A series is held at the host's wall-clock time, so a weekly 17:00 in Berlin
  stays at 17:00 when the clocks change, and its UTC instant moves instead.
  Each start is the first's local time on a stepped local date, converted
  back to UTC:

    * `:daily` steps `interval` days, `:weekly` `7 * interval` days;
    * `:monthly` steps `interval` months and keeps the weekday ordinal of the
      first date (the 2nd Thursday stays the 2nd Thursday). A fifth weekday
      falls back to the month's last such weekday where there is no fifth.

  A local time the clocks skip (spring forward) moves to the first instant
  after the gap; one they repeat (fall back) takes the earlier instant.

  Pure: no database, no clock.
  """

  @type frequency :: :daily | :weekly | :monthly

  @doc """
  `count` UTC starts, the first equal to `first_start`, stepped by
  `frequency` and `interval` in `host_timezone`'s wall-clock time.
  """
  @spec recurring_starts(DateTime.t(), frequency(), 1..4, pos_integer(), String.t()) ::
          [DateTime.t()]
  def recurring_starts(%DateTime{} = first_start, frequency, interval, count, host_timezone)
      when frequency in [:daily, :weekly, :monthly] and is_integer(interval) and interval > 0 and
             is_integer(count) and count > 0 do
    local = DateTime.shift_zone!(first_start, host_timezone)
    first_date = DateTime.to_date(local)
    time = DateTime.to_time(local)

    later =
      for step <- 1..(count - 1)//1 do
        first_date
        |> step_date(frequency, interval * step)
        |> at_local_time(time, host_timezone)
      end

    [first_start | later]
  end

  defp step_date(date, :daily, days), do: Date.add(date, days)
  defp step_date(date, :weekly, weeks), do: Date.add(date, 7 * weeks)

  defp step_date(date, :monthly, months) do
    ordinal = div(date.day - 1, 7) + 1
    first_of_month = date |> Date.beginning_of_month() |> Date.shift(month: months)
    nth_weekday(first_of_month, Date.day_of_week(date), ordinal)
  end

  # The `ordinal`th `weekday` of the month starting at `first_of_month`, or
  # the last one when the month has fewer.
  defp nth_weekday(first_of_month, weekday, ordinal) do
    offset = Integer.mod(weekday - Date.day_of_week(first_of_month), 7)
    candidate = Date.add(first_of_month, offset + 7 * (ordinal - 1))

    if candidate.month == first_of_month.month,
      do: candidate,
      else: Date.add(candidate, -7)
  end

  defp at_local_time(date, time, timezone) do
    naive = NaiveDateTime.new!(date, time)

    local =
      case DateTime.from_naive(naive, timezone) do
        {:ok, datetime} -> datetime
        {:ambiguous, earlier, _later} -> earlier
        {:gap, _before, just_after} -> just_after
      end

    DateTime.shift_zone!(local, "Etc/UTC")
  end
end
