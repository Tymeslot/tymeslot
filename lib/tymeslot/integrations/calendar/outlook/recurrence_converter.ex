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
  """
  @spec rrule_to_outlook(String.t() | nil, Date.t()) :: map() | nil
  def rrule_to_outlook(nil, _start_date), do: nil
  def rrule_to_outlook("", _start_date), do: nil

  def rrule_to_outlook(rrule, %Date{} = start_date) when is_binary(rrule) do
    parsed = RRule.parse(rrule)

    case Map.get(parsed, :freq) do
      nil ->
        nil

      _freq ->
        %{
          "pattern" => build_pattern(parsed, start_date),
          "range" => build_range(parsed, start_date)
        }
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
