defmodule Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter do
  @moduledoc """
  Converts between RFC-5545 RRULE strings and the structured `recurrence`
  object Microsoft Graph requires (`%{"pattern" => ..., "range" => ...}`).

  Graph does not accept RRULE strings, so the write path must translate the
  canonical `recurrence_rule` field into a pattern/range pair, and the read
  path must translate it back. Pure data transformations — no side effects.

  ## Coverage limits

  Only the recurrence editor's surface is supported: daily, weekly (with
  `BYDAY` → `daysOfWeek`), monthly (`absoluteMonthly`, anchored on the event's
  start day-of-month) and yearly (`absoluteYearly`). Graph's relative patterns
  (`relativeMonthly`/`relativeYearly` with `BYSETPOS`) are intentionally out of
  scope. Monthly/yearly RRULEs round-trip back without a `BYMONTHDAY`/`BYMONTH`
  part because the anchor is reconstructed from the event's start date, not the
  RRULE.

  ## Days some months lack

  The two calendars read a monthly day the month lacks differently: RFC 5545
  skips the month, so a series on the 31st has no occurrence in April, while
  Graph moves it to the month's last day. Graph has no pattern that skips, so
  a series that would reach such a month is refused
  (`{:error, :day_missing_in_some_months}`) rather than written with dates the
  organiser never chose. A yearly series from 29 February is refused the same
  way, unless it ends before a common year.
  """

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

  @weekday_to_graph %{
    mo: "monday",
    tu: "tuesday",
    we: "wednesday",
    th: "thursday",
    fr: "friday",
    sa: "saturday",
    su: "sunday"
  }
  @graph_to_weekday Map.new(@weekday_to_graph, fn {atom, name} -> {name, atom} end)

  @doc """
  Converts an RRULE string into a Microsoft Graph `recurrence` object.

  The `start_date` supplies the range `startDate` and anchors monthly/yearly
  patterns (and a weekly pattern that omits `BYDAY`).

  `timezone` is the event's own zone, and it is what makes the range's
  `endDate` right. A timed rule's UNTIL is an instant in UTC, while Graph reads
  `endDate` as a *local* date in the event's timezone (Graph's own default when
  no `recurrenceTimeZone` is sent, which this converter never sends). Parsing
  without the zone reads the UNTIL as a UTC date, so an organiser west of UTC
  had the series written one day late and Graph generated an extra occurrence.

  Returns `nil` for a missing or unreadable rule, and
  `{:error, :day_missing_in_some_months}` for a monthly or yearly series that
  Graph would move onto a month's last day (see the moduledoc).
  """
  @spec rrule_to_outlook(String.t() | nil, Date.t(), String.t() | nil) ::
          map() | nil | {:error, :day_missing_in_some_months}
  def rrule_to_outlook(rrule, start_date, timezone \\ nil)
  def rrule_to_outlook(nil, _start_date, _timezone), do: nil
  def rrule_to_outlook("", _start_date, _timezone), do: nil

  def rrule_to_outlook(rrule, %Date{} = start_date, timezone) when is_binary(rrule) do
    parsed = RRule.parse(rrule, timezone: timezone)

    case Map.get(parsed, :freq) do
      nil ->
        nil

      freq ->
        if moves_to_month_end?(freq, parsed, start_date) do
          {:error, :day_missing_in_some_months}
        else
          %{
            "pattern" => build_pattern(parsed, start_date),
            "range" => build_range(parsed, start_date)
          }
        end
    end
  end

  @doc """
  Converts a Microsoft Graph `recurrence` object back into an RRULE string.

  Returns `nil` when the map is not a recognisable pattern/range pair.
  """
  @spec outlook_to_rrule(map() | nil) :: String.t() | nil
  def outlook_to_rrule(%{"pattern" => pattern, "range" => range})
      when is_map(pattern) and is_map(range) do
    case build_opts(pattern, range) do
      nil -> nil
      opts -> RRule.build(opts)
    end
  end

  def outlook_to_rrule(_other), do: nil

  # --- rrule -> outlook ---

  # Graph's dates are the start date shifted by whole periods, each clamped to
  # the month's last day (as `Date.shift/2` clamps), so the series is moved
  # somewhere exactly when one of those dates is not on the start's day. An
  # open-ended series is walked over a full Gregorian cycle, which also finds
  # the common year that a 29 February series every fourth year reaches.
  @gregorian_cycle_months 400 * 12

  defp moves_to_month_end?(freq, parsed, %Date{day: day} = start_date)
       when freq in [:monthly, :yearly] and day > 28 do
    step = Map.get(parsed, :interval, 1) * if(freq == :yearly, do: 12, else: 1)
    until = Map.get(parsed, :until)

    0
    |> Stream.iterate(&(&1 + step))
    |> Stream.take(Map.get(parsed, :count, div(@gregorian_cycle_months, step) + 1))
    |> Stream.map(&Date.shift(start_date, month: &1))
    |> Stream.take_while(&(is_nil(until) or Date.compare(&1, until) != :gt))
    |> Enum.any?(&(&1.day != day))
  end

  defp moves_to_month_end?(_freq, _parsed, _start_date), do: false

  defp build_pattern(parsed, start_date) do
    interval = Map.get(parsed, :interval, 1)

    parsed
    |> Map.get(:freq)
    |> pattern_for_freq(parsed, start_date)
    |> Map.put("interval", interval)
  end

  defp pattern_for_freq(:daily, _parsed, _start_date), do: %{"type" => "daily"}

  defp pattern_for_freq(:weekly, parsed, start_date) do
    %{"type" => "weekly", "daysOfWeek" => days_of_week(parsed, start_date)}
  end

  defp pattern_for_freq(:monthly, _parsed, start_date) do
    %{"type" => "absoluteMonthly", "dayOfMonth" => start_date.day}
  end

  defp pattern_for_freq(:yearly, _parsed, start_date) do
    %{"type" => "absoluteYearly", "dayOfMonth" => start_date.day, "month" => start_date.month}
  end

  defp days_of_week(parsed, start_date) do
    case Map.get(parsed, :by_day, []) do
      [] -> [start_date |> Date.day_of_week() |> weekday_index_to_graph()]
      days -> Enum.map(days, &Map.fetch!(@weekday_to_graph, &1))
    end
  end

  # Date.day_of_week/1 returns 1 (Monday) .. 7 (Sunday).
  @graph_weekdays_by_index {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                            "sunday"}
  defp weekday_index_to_graph(index), do: elem(@graph_weekdays_by_index, index - 1)

  defp build_range(parsed, start_date) do
    base = %{"startDate" => Date.to_iso8601(start_date)}

    cond do
      count = Map.get(parsed, :count) ->
        Map.merge(base, %{"type" => "numbered", "numberOfOccurrences" => count})

      until = Map.get(parsed, :until) ->
        Map.merge(base, %{"type" => "endDate", "endDate" => Date.to_iso8601(until)})

      true ->
        Map.put(base, "type", "noEnd")
    end
  end

  # --- outlook -> rrule ---

  defp build_opts(pattern, range) do
    case freq_for_pattern(pattern["type"]) do
      nil ->
        nil

      freq ->
        %{freq: freq}
        |> put_interval(pattern)
        |> put_by_day(freq, pattern)
        |> put_range(range)
    end
  end

  defp freq_for_pattern("daily"), do: :daily
  defp freq_for_pattern("weekly"), do: :weekly
  defp freq_for_pattern("absoluteMonthly"), do: :monthly
  defp freq_for_pattern("absoluteYearly"), do: :yearly
  defp freq_for_pattern(_other), do: nil

  defp put_interval(opts, %{"interval" => interval}) when is_integer(interval),
    do: Map.put(opts, :interval, interval)

  defp put_interval(opts, _pattern), do: opts

  defp put_by_day(opts, :weekly, %{"daysOfWeek" => days}) when is_list(days) do
    by_day =
      days
      |> Enum.map(&Map.get(@graph_to_weekday, String.downcase(&1)))
      |> Enum.reject(&is_nil/1)

    if by_day == [], do: opts, else: Map.put(opts, :by_day, by_day)
  end

  defp put_by_day(opts, _freq, _pattern), do: opts

  defp put_range(opts, %{"type" => "numbered", "numberOfOccurrences" => count})
       when is_integer(count),
       do: Map.put(opts, :count, count)

  defp put_range(opts, %{"type" => "endDate", "endDate" => end_date}) when is_binary(end_date) do
    case Date.from_iso8601(end_date) do
      {:ok, date} -> Map.put(opts, :until, date)
      {:error, _reason} -> opts
    end
  end

  defp put_range(opts, _range), do: opts
end
