defmodule Tymeslot.Integrations.Calendar.Recurrence.RRule.Until do
  @moduledoc """
  What a rule's `UNTIL` means, read and written in the series' own zone.

  RFC 5545 §3.3.10 gives `UNTIL` the value type of the series' `DTSTART`, so
  one value can be written four ways:

    * a bare `YYYYMMDD`, for an all-day series: a calendar date, zone-free;
    * `YYYYMMDDTHHMMSSZ`, for a timed series: an instant in UTC;
    * `YYYYMMDDTHHMMSS`, for a floating series: a wall clock, read in the
      zone the series is shown in;
    * `YYYYMMDDT235959Z`, which this module once wrote for the organiser's
      local date and `Outlook.RecurrenceConverter` still writes for a Graph
      `endDate`: a local date, not an instant (see `local_date/2`).

  The recurrence editor reads a value as the date the organiser picked
  (`local_date/2`) and writes a date back as the instant that ends it
  (`format/3`); the expander bounds a series by the instant (`instant/2`).
  Both read a value in the same zone, so the last occurrence the expander
  makes falls on the date the editor shows.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @end_of_day ~T[23:59:59]
  @start_of_day ~T[00:00:00]
  @utc "Etc/UTC"

  # See `local_date/2`: an UNTIL ending in this is a local date stamped with
  # end-of-day UTC, not an instant to be shifted into the event's timezone.
  @legacy_utc_end_of_day "T235959Z"

  @doc """
  Writes `date` as an `UNTIL` value. An all-day series takes the bare date;
  a timed one the instant that ends `date` in `timezone`, in UTC, so the
  chosen date is fully included wherever the organiser is. Without a
  timezone the day is ended in UTC.
  """
  @spec format(Date.t(), boolean(), String.t() | nil) :: String.t()
  def format(%Date{} = date, true = _all_day, _timezone), do: Date.to_iso8601(date, :basic)

  def format(%Date{} = date, _all_day, timezone) do
    date
    |> end_of_day(timezone)
    |> DateTime.shift_zone!(@utc)
    |> DateTime.to_iso8601(:basic)
  end

  @doc """
  The date the organiser picked: the date a UTC `UNTIL` falls on in
  `timezone`, or the date any other form spells. `:error` when the value
  holds no date.

  `T235959Z` is the exception among the UTC forms, and it is a legacy marker
  rather than an instant. Rules written before `UNTIL` carried the event's
  timezone stamped the organiser's local date with a literal end-of-day
  *UTC*, so reading one back through a timezone shifts it onto the next
  local day everywhere east of UTC, silently extending the series.
  `Outlook.RecurrenceConverter` also builds this form from a Graph
  `endDate`, which is likewise a local date. The form is safe to
  special-case because it is never ambiguous: end-of-day in a zero-offset
  zone is the only case `format/3` writes as `T235959Z`, and there the
  instant and the date it spells are the same day.
  """
  @spec local_date(String.t(), String.t() | nil) :: {:ok, Date.t()} | :error
  def local_date(value, timezone) when is_binary(value) do
    if String.ends_with?(value, @legacy_utc_end_of_day) do
      basic_date(value)
    else
      case local_date_of_instant(value, timezone) do
        {:ok, date} -> {:ok, date}
        :error -> basic_date(value)
      end
    end
  end

  @doc """
  The last instant a series may start at, read in `zone`, the zone its
  occurrences are stepped in: a UTC value as written, a floating one as a
  wall clock in `zone`, and a date (bare, or the legacy `T235959Z` marker)
  as the end of that day in `zone`. `nil` for a value that holds no date,
  which leaves the series unbounded.
  """
  @spec instant(String.t(), String.t()) :: DateTime.t() | nil
  def instant(value, zone) when is_binary(value) do
    cond do
      String.ends_with?(value, @legacy_utc_end_of_day) -> date_end(value, zone)
      String.ends_with?(value, "Z") -> utc_instant(value)
      String.contains?(value, "T") -> wall_clock(value, zone)
      true -> date_end(value, zone)
    end
  end

  defp utc_instant(value) do
    case DateTime.from_iso8601(value, Calendar.ISO, :basic) do
      {:ok, instant, _offset} -> instant
      _invalid -> nil
    end
  end

  defp wall_clock(value, zone) do
    with <<_date::binary-8, "T", h::binary-2, m::binary-2, sec::binary-2, _rest::binary>> <- value,
         {:ok, date} <- basic_date(value),
         {:ok, time} <- Time.from_iso8601("#{h}:#{m}:#{sec}") do
      DateTimeUtils.create_datetime_safe(date, time, zone)
    else
      _invalid -> nil
    end
  end

  defp date_end(value, zone) do
    case basic_date(value) do
      {:ok, date} -> end_of_day(date, zone)
      :error -> nil
    end
  end

  # Built as the next local day's first instant less a second, rather than as
  # 23:59:59 on this one. The two agree on an ordinary day and diverge where a
  # DST transition makes 23:59:59 ambiguous: `create_datetime_safe/3` resolves
  # an ambiguous wall clock to the *first* of the pair, which is right for a
  # start instant and an hour early for an upper bound, so a series ending on
  # the transition date in Cairo, Beirut or Amman dropped its last evening
  # occurrence. Midnight is the one wall clock on a day that cannot be
  # ambiguous in that direction: where it repeats, the earlier of the two is
  # still the first instant to carry the new date, which is exactly the bound
  # wanted, and where it does not exist the subtraction is instant arithmetic
  # and lands on the real last second regardless.
  #
  # `create_datetime_safe/3` applies the project-wide rule for a wall-clock
  # time that a DST transition makes ambiguous or non-existent, and falls back
  # to UTC when the timezone is not one tzdata knows.
  defp end_of_day(date, timezone) when is_binary(timezone) do
    date
    |> Date.add(1)
    |> DateTimeUtils.create_datetime_safe(@start_of_day, timezone)
    |> DateTime.add(-1, :second)
  end

  defp end_of_day(date, _no_timezone), do: DateTime.new!(date, @end_of_day, @utc)

  defp local_date_of_instant(value, timezone) when is_binary(timezone) do
    with {:ok, instant, _offset} <- DateTime.from_iso8601(value, Calendar.ISO, :basic),
         {:ok, local} <- DateTime.shift_zone(instant, timezone) do
      {:ok, DateTime.to_date(local)}
    else
      _other -> :error
    end
  end

  defp local_date_of_instant(_value, _no_timezone), do: :error

  defp basic_date(value) do
    with <<y::binary-4, m::binary-2, d::binary-2, _rest::binary>> <- String.slice(value, 0, 10),
         {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date}
    else
      _other -> :error
    end
  end
end
