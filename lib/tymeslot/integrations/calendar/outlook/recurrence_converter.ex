defmodule Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter do
  @moduledoc """
  Converts between RFC-5545 RRULE strings and the structured `recurrence`
  object Microsoft Graph requires (`%{"pattern" => ..., "range" => ...}`).

  Graph does not accept RRULE strings, so the write path must translate the
  canonical `recurrence_rule` field into a pattern/range pair, and the read
  path must translate it back. Pure data transformations — no side effects.

  ## Patterns

    * daily, and a daily rule on some weekdays (`FREQ=DAILY;BYDAY=MO,TU`),
      which Graph only has as a weekly pattern on those days;
    * weekly, with `BYDAY` → `daysOfWeek` (the start's weekday without one);
    * `absoluteMonthly` on the start's day of the month, or on the one day
      a `BYMONTHDAY` names; `absoluteYearly` likewise, in the month a
      `BYMONTH` names;
    * `relativeMonthly` for one weekday counted within the month
      (`BYDAY=2TU`, the second Tuesday; `-1FR`, the last Friday), or a set
      of weekdays with one `BYSETPOS` (`BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1`,
      the last weekday); `relativeYearly` likewise, in one `BYMONTH`. Graph
      counts the first to the fourth, and the last.

  A rule Graph has no pattern for is refused
  (`{:error, :rule_not_supported_by_outlook}`) rather than written as the
  nearest pattern, which would put the series on other dates without any
  sign of it: several counted weekdays, a fifth or second-to-last one,
  several days of the month or one counted from its end, several months,
  and any part beyond these (`BYHOUR`, `BYWEEKNO`, ...).

  Absolute monthly and yearly patterns read back without a `BYMONTHDAY` or
  `BYMONTH` part, since the event's start date anchors them.

  ## Days some months lack

  The two calendars read a monthly day the month lacks differently: RFC 5545
  skips the month, so a series on the 31st has no occurrence in April, while
  Graph moves it to the month's last day. Graph has no pattern that skips, so
  an absolute series that would reach such a month is refused
  (`{:error, :day_missing_in_some_months}`) rather than written with dates the
  organiser never chose. A yearly series on 29 February is refused the same
  way, unless it ends before a common year.

  ## Week start

  An every-other-week series on several days fires in alternate weeks, and
  which days share a week depends on the day the week starts on: `WKST` in
  the rule (Monday unless stated), `firstDayOfWeek` in a Graph pattern
  (Sunday unless stated). A weekly pattern is written with the rule's week
  start, and read back with `WKST` whenever it starts on another day than
  Monday, so a Sunday-and-Monday fortnightly series keeps its Sundays in the
  same weeks both ways. No other pattern depends on it, so no other pattern
  carries it.
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

  @weekday_to_iso ~w(mo tu we th fr sa su)a |> Enum.with_index(1) |> Map.new()

  # Graph's `index` for each `BYDAY` ordinal or `BYSETPOS` it can express.
  @ordinal_to_index %{1 => "first", 2 => "second", 3 => "third", 4 => "fourth", -1 => "last"}
  @index_to_ordinal Map.new(@ordinal_to_index, fn {ordinal, index} -> {index, ordinal} end)

  @doc """
  Converts an RRULE string into a Microsoft Graph `recurrence` object, or
  `nil` for no rule or one without a readable `FREQ`, as before; a rule
  Graph has no pattern for is refused (see "Patterns"), and so is a monthly
  or yearly series Graph would move onto a month's last day
  (`{:error, :day_missing_in_some_months}`; see "Days some months lack").

  The `start_date` supplies the range `startDate` and anchors monthly/yearly
  patterns (and a weekly pattern that omits `BYDAY`).

  `timezone` is the event's own zone, and it is what makes the range's
  `endDate` right. A timed rule's UNTIL is an instant in UTC, while Graph reads
  `endDate` as a *local* date in the event's timezone (Graph's own default when
  no `recurrenceTimeZone` is sent, which this converter never sends). Parsing
  without the zone reads the UNTIL as a UTC date, so an organiser west of UTC
  had the series written one day late and Graph generated an extra occurrence.
  """
  @spec rrule_to_outlook(String.t() | nil, Date.t(), String.t() | nil) ::
          {:ok, map() | nil}
          | {:error, :rule_not_supported_by_outlook | :day_missing_in_some_months}
  def rrule_to_outlook(rrule, start_date, timezone \\ nil)
  def rrule_to_outlook(nil, _start_date, _timezone), do: {:ok, nil}
  def rrule_to_outlook("", _start_date, _timezone), do: {:ok, nil}

  def rrule_to_outlook(rrule, %Date{} = start_date, timezone) when is_binary(rrule) do
    with {:ok, rule} <- RRule.parse(rrule),
         {:ok, pattern} <- pattern(rule, start_date),
         options = RRule.options(rule, timezone: timezone),
         :ok <- refuse_moved_days(pattern, rule.interval, options, start_date) do
      {:ok,
       %{
         "pattern" =>
           pattern |> Map.put("interval", rule.interval) |> put_first_day_of_week(rule),
         "range" => build_range(options, start_date)
       }}
    else
      :error -> {:ok, nil}
      {:error, _unsupported} = refused -> refused
    end
  end

  @doc """
  Converts a Microsoft Graph `recurrence` object back into an RRULE string.

  Returns `nil` when the map is not a recognisable pattern/range pair.
  """
  @spec outlook_to_rrule(map() | nil) :: String.t() | nil
  def outlook_to_rrule(%{"pattern" => pattern, "range" => range})
      when is_map(pattern) and is_map(range) do
    with %{} = opts <- build_opts(pattern, range),
         {:ok, parts} <- relative_parts(pattern) do
      {:ok, rule} = opts |> RRule.build() |> RRule.parse()

      rule
      |> put_parts(parts)
      |> Map.put(:week_start, week_start(pattern))
      |> RRule.format()
    else
      _unreadable -> nil
    end
  end

  def outlook_to_rrule(_other), do: nil

  # --- rrule -> outlook ---

  defp pattern(%RRule{other: [_part | _rest]}, _start_date), do: refused()

  defp pattern(%RRule{freq: :daily} = rule, _start_date) do
    case {rule.by_day, rule.by_month_day, rule.by_month, rule.by_set_pos, rule.interval} do
      {nil, nil, nil, nil, _interval} -> {:ok, %{"type" => "daily"}}
      {by_day, nil, nil, nil, 1} -> weekly(by_day, nil)
      _other -> refused()
    end
  end

  defp pattern(
         %RRule{freq: :weekly, by_month_day: nil, by_month: nil, by_set_pos: nil} = rule,
         start_date
       ),
       do: weekly(rule.by_day, start_date)

  defp pattern(%RRule{freq: :monthly, by_month: nil} = rule, start_date) do
    case {rule.by_day, rule.by_month_day, rule.by_set_pos} do
      {nil, nil, nil} -> {:ok, %{"type" => "absoluteMonthly", "dayOfMonth" => start_date.day}}
      {nil, [day], nil} when day > 0 -> {:ok, %{"type" => "absoluteMonthly", "dayOfMonth" => day}}
      {by_day, nil, by_set_pos} -> relative("relativeMonthly", by_day, by_set_pos)
      _other -> refused()
    end
  end

  defp pattern(%RRule{freq: :yearly, by_month: nil} = rule, start_date) do
    if {rule.by_day, rule.by_month_day, rule.by_set_pos} == {nil, nil, nil},
      do: {:ok, absolute_yearly(start_date.day, start_date.month)},
      else: refused()
  end

  defp pattern(%RRule{freq: :yearly, by_month: [month]} = rule, start_date) do
    case {rule.by_day, rule.by_month_day, rule.by_set_pos} do
      {nil, nil, nil} ->
        {:ok, absolute_yearly(start_date.day, month)}

      {nil, [day], nil} when day > 0 ->
        {:ok, absolute_yearly(day, month)}

      {by_day, nil, by_set_pos} ->
        with {:ok, pattern} <- relative("relativeYearly", by_day, by_set_pos),
             do: {:ok, Map.put(pattern, "month", month)}

      _other ->
        refused()
    end
  end

  defp pattern(_rule, _start_date), do: refused()

  defp absolute_yearly(day, month),
    do: %{"type" => "absoluteYearly", "dayOfMonth" => day, "month" => month}

  # Without `BYDAY`, a weekly series repeats on its start's weekday.
  defp weekly(nil, %Date{} = start_date),
    do:
      {:ok,
       %{
         "type" => "weekly",
         "daysOfWeek" => [start_date |> Date.day_of_week() |> weekday_index_to_graph()]
       }}

  defp weekly(by_day, _start_date) when is_list(by_day) do
    if Enum.all?(by_day, &match?({nil, _weekday}, &1)),
      do: {:ok, %{"type" => "weekly", "daysOfWeek" => graph_days(by_day)}},
      else: refused()
  end

  defp weekly(_by_day, _start_date), do: refused()

  # One weekday counted within the period, or a set of weekdays one of which
  # `BYSETPOS` picks.
  defp relative(type, [{ordinal, _weekday}] = by_day, nil)
       when is_map_key(@ordinal_to_index, ordinal),
       do: {:ok, relative_pattern(type, by_day, ordinal)}

  defp relative(type, [_first | _rest] = by_day, [position])
       when is_map_key(@ordinal_to_index, position) do
    if Enum.all?(by_day, &match?({nil, _weekday}, &1)),
      do: {:ok, relative_pattern(type, by_day, position)},
      else: refused()
  end

  defp relative(_type, _by_day, _by_set_pos), do: refused()

  defp relative_pattern(type, by_day, ordinal) do
    %{
      "type" => type,
      "daysOfWeek" => graph_days(by_day),
      "index" => Map.fetch!(@ordinal_to_index, ordinal)
    }
  end

  defp graph_days(by_day),
    do: Enum.map(by_day, fn {_ordinal, iso} -> weekday_index_to_graph(iso) end)

  defp refused, do: {:error, :rule_not_supported_by_outlook}

  # Graph places an absolute series on its day in every period, moved to the
  # month's last day where the month lacks it; RFC 5545 skips that period
  # instead. So the series is refused exactly when one of the periods it
  # reaches lacks its day. An open-ended series is walked over a full
  # Gregorian cycle, which also finds the common year that a 29 February
  # series every fourth year reaches.
  @gregorian_cycle_months 400 * 12

  defp refuse_moved_days(
         %{"type" => type, "dayOfMonth" => day} = pattern,
         interval,
         options,
         start
       )
       when type in ["absoluteMonthly", "absoluteYearly"] and day > 28 do
    {first_month, step} =
      if type == "absoluteYearly",
        do: {Date.new!(start.year, pattern["month"], 1), interval * 12},
        else: {Date.beginning_of_month(start), interval}

    until = Map.get(options, :until)

    moved? =
      first_month
      |> Stream.iterate(&Date.shift(&1, month: step))
      |> Stream.map(&graph_occurrence(&1, day))
      |> Stream.drop_while(fn {date, _moved?} -> Date.before?(date, start) end)
      |> Stream.take(Map.get(options, :count, div(@gregorian_cycle_months, step) + 1))
      |> Stream.take_while(fn {date, _moved?} ->
        is_nil(until) or not Date.after?(date, until)
      end)
      |> Enum.any?(fn {_date, moved?} -> moved? end)

    if moved?, do: {:error, :day_missing_in_some_months}, else: :ok
  end

  defp refuse_moved_days(_pattern, _interval, _options, _start), do: :ok

  defp graph_occurrence(month_start, day) do
    case Date.new(month_start.year, month_start.month, day) do
      {:ok, date} -> {date, false}
      {:error, _invalid} -> {Date.end_of_month(month_start), true}
    end
  end

  defp put_first_day_of_week(%{"type" => "weekly"} = pattern, rule),
    do: Map.put(pattern, "firstDayOfWeek", weekday_index_to_graph(rule.week_start || 1))

  defp put_first_day_of_week(pattern, _rule), do: pattern

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
  defp freq_for_pattern("relativeMonthly"), do: :monthly
  defp freq_for_pattern("relativeYearly"), do: :yearly
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

  # The parts a relative pattern adds to the rule `build_opts/2` gives, the
  # inverse of `relative/3`. Graph's `index` defaults to the first.
  defp relative_parts(%{"type" => type, "daysOfWeek" => [_day | _rest] = days} = pattern)
       when type in ["relativeMonthly", "relativeYearly"] do
    ordinal = Map.get(@index_to_ordinal, Map.get(pattern, "index", "first"))
    weekdays = Enum.map(days, &graph_to_iso/1)
    month = if type == "relativeYearly", do: pattern["month"], else: :none

    cond do
      is_nil(ordinal) or nil in weekdays -> :error
      month != :none and month not in 1..12 -> :error
      true -> {:ok, %{by_day: weekdays, ordinal: ordinal, month: month}}
    end
  end

  defp relative_parts(%{"type" => type}) when type in ["relativeMonthly", "relativeYearly"],
    do: :error

  defp relative_parts(_pattern), do: {:ok, nil}

  defp put_parts(rule, nil), do: rule

  defp put_parts(rule, %{by_day: weekdays, ordinal: ordinal, month: month}) do
    {by_day, by_set_pos} =
      case weekdays do
        [weekday] -> {[{ordinal, weekday}], nil}
        several -> {Enum.map(several, &{nil, &1}), [ordinal]}
      end

    %{
      rule
      | by_day: by_day,
        by_set_pos: by_set_pos,
        by_month: if(month == :none, do: nil, else: [month])
    }
  end

  # Graph's own default is Sunday; Monday is the RRULE default, so it is left
  # unstated. A day Graph does not name is left unstated too.
  defp week_start(%{"type" => "weekly"} = pattern) do
    case graph_to_iso(Map.get(pattern, "firstDayOfWeek") || "sunday") do
      1 -> nil
      iso -> iso
    end
  end

  defp week_start(_pattern), do: nil

  defp graph_to_iso(name) when is_binary(name) do
    case Map.get(@graph_to_weekday, String.downcase(name)) do
      nil -> nil
      weekday -> Map.fetch!(@weekday_to_iso, weekday)
    end
  end

  defp graph_to_iso(_name), do: nil
end
