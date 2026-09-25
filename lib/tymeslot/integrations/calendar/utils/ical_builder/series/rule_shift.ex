defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series.RuleShift do
  @moduledoc """
  Keeping a series' `RRULE` in step with a move of its `DTSTART`
  (`ICalBuilder.Series.edit_master/5`).

  Most rules take the day and time of their occurrences from `DTSTART`, and
  follow a move of it unchanged. Some name them outright, and would leave
  the occurrences where they were while the exceptions and overrides moved:

    * `BYDAY` with plain weekdays in a `WEEKLY` or `DAILY` rule is rotated by
      the number of days the series moved, so a weekly Monday meeting moved
      to Tuesday reads `BYDAY=TU`. Every other part stays as written.
    * Anything else that names a day (an ordinal `BYDAY` such as `2MO`,
      `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`, `BYSETPOS`, `BYMONTH`) cannot
      follow a move to another date, and any move at all is refused for a
      time part (`BYHOUR`, `BYMINUTE`, `BYSECOND`), with
      `{:error, :rule_pins_occurrences}`.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines

  @weekdays ~w(MO TU WE TH FR SA SU)
  @day_parts ~w(BYMONTHDAY BYYEARDAY BYWEEKNO BYSETPOS BYMONTH)
  @time_parts ~w(BYHOUR BYMINUTE BYSECOND)
  @rotatable_frequencies ~w(WEEKLY DAILY)

  @doc """
  The `RRULE` content line `line` for a series moved by `shift` seconds, of
  which `days` whole dates: `0` when the move stays on the same date.
  """
  @spec follow(String.t(), integer(), integer()) ::
          {:ok, String.t()} | {:error, :rule_pins_occurrences}
  def follow(line, 0, _days), do: {:ok, line}

  def follow(line, _shift, days) do
    {name_and_params, value} = ContentLines.split_value(line)
    parts = parse(value)

    cond do
      has_any?(parts, @time_parts) -> pinned()
      days == 0 -> {:ok, line}
      has_any?(parts, @day_parts) -> pinned()
      not has_any?(parts, ["BYDAY"]) -> {:ok, line}
      true -> rotate(name_and_params, parts, days)
    end
  end

  defp rotate(name_and_params, parts, days) do
    weekdays = parts |> part("BYDAY") |> String.upcase() |> String.split(",", trim: true)

    if rotatable?(parts, weekdays) and not crosses_week?(parts, weekdays, days) do
      rotated = Enum.map_join(weekdays, ",", &rotate_weekday(&1, days))
      {:ok, name_and_params <> ":" <> join(put_part(parts, "BYDAY", rotated))}
    else
      pinned()
    end
  end

  # An ordinal (`2MO`, `-1FR`) names a week of the month or year, which a
  # move of whole days does not map onto another one.
  defp rotatable?(parts, weekdays) do
    String.upcase(part(parts, "FREQ") || "") in @rotatable_frequencies and weekdays != [] and
      Enum.all?(weekdays, &(&1 in @weekdays))
  end

  # A WEEKLY rule with an INTERVAL above one fires every n-th week, counted
  # in weeks that start on WKST (Monday unless stated; RFC 5545 §3.3.10). A
  # weekday rotated past WKST lands in the next (or previous) week, which
  # may not be one that fires, so the rotated rule could produce occurrences
  # in other weeks than the moved series. That case is refused rather than
  # guessed at; WKST itself is kept as written. A DAILY rule counts its
  # INTERVAL in days, from DTSTART, so BYDAY there is a filter that moves
  # with it whatever the interval.
  defp crosses_week?(parts, weekdays, days) do
    weekly? = String.upcase(part(parts, "FREQ") || "") == "WEEKLY"
    interval = interval(part(parts, "INTERVAL"))
    week_start = index(String.upcase(part(parts, "WKST") || "MO"))

    weekly? and interval > 1 and
      Enum.any?(weekdays, fn weekday ->
        position = Integer.mod(index(weekday) - week_start, 7) + days
        position < 0 or position > 6
      end)
  end

  defp interval(nil), do: 1

  defp interval(written) do
    case Integer.parse(written) do
      {interval, ""} -> interval
      _unreadable -> 1
    end
  end

  defp rotate_weekday(weekday, days),
    do: Enum.at(@weekdays, Integer.mod(index(weekday) + days, 7))

  defp index(weekday), do: Enum.find_index(@weekdays, &(&1 == weekday)) || 0

  defp pinned, do: {:error, :rule_pins_occurrences}

  # Parts are kept as written, name and value, so everything the rotation
  # does not touch goes back exactly as the server had it.
  defp parse(value) do
    value
    |> String.split(";", trim: true)
    |> Enum.map(fn written ->
      case String.split(written, "=", parts: 2) do
        [name, part_value] -> {name, part_value}
        [name] -> {name, nil}
      end
    end)
  end

  defp part(parts, name) do
    Enum.find_value(parts, fn {written, value} -> if String.upcase(written) == name, do: value end)
  end

  defp has_any?(parts, names),
    do: Enum.any?(parts, fn {name, _value} -> String.upcase(name) in names end)

  defp put_part(parts, name, value) do
    Enum.map(parts, fn {written, _old} = part ->
      if String.upcase(written) == name, do: {written, value}, else: part
    end)
  end

  defp join(parts) do
    Enum.map_join(parts, ";", fn
      {name, nil} -> name
      {name, value} -> name <> "=" <> value
    end)
  end
end
