defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series.RuleShift do
  @moduledoc """
  Keeping a series' `RRULE` in step with a move of its `DTSTART`
  (`ICalBuilder.Series.edit_master/5`).

  Most rules take the day and time of their occurrences from `DTSTART`, and
  follow a move of it unchanged. Some name them outright, and would leave
  the occurrences where they were while the exceptions and overrides moved:

    * `BYDAY` with plain weekdays in a `WEEKLY` or `DAILY` rule is rotated by
      the number of days the series moved, so a weekly Monday meeting moved
      to Tuesday reads `BYDAY=TU`. Every other part but `UNTIL` stays as
      written.
    * Anything else that names a day (an ordinal `BYDAY` such as `2MO`,
      `BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`, `BYSETPOS`, `BYMONTH`) cannot
      follow a move to another date, and any move at all is refused for a
      time part (`BYHOUR`, `BYMINUTE`, `BYSECOND`), with
      `{:error, :rule_pins_occurrences}`.
    * `UNTIL` moves with the series (`Series.Shift.shift_bound/4`), in the
      form it is written in, so the last occurrences are not pushed past
      the end of the series and dropped. `COUNT` needs nothing.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Shift

  @weekdays ~w(MO TU WE TH FR SA SU)
  @day_parts ~w(BYMONTHDAY BYYEARDAY BYWEEKNO BYSETPOS BYMONTH)
  @time_parts ~w(BYHOUR BYMINUTE BYSECOND)
  @rotatable_frequencies ~w(WEEKLY DAILY)

  @doc """
  The `RRULE` content line `line` for a series moved by `shift` seconds on
  the wall clock of its zone, of which `days` whole dates: `0` when the move
  stays on the same date.

  Options:

    * `:zone` - the series' zone, which a UTC `UNTIL` moves on the wall
      clock of (UTC when `nil`, the default);
    * `:keep_until` - `true` for a rule whose end is not the series' to
      move: one the organiser stated in the same edit, which is written as
      they gave it. Defaults to `false`.
  """
  @spec follow(String.t(), integer(), integer(), keyword()) ::
          {:ok, String.t()}
          | {:error, :rule_pins_occurrences | :unsupported_value | :unreadable_timing}
  def follow(line, shift, days, opts \\ [])
  def follow(line, 0, _days, _opts), do: {:ok, line}

  def follow(line, shift, days, opts) do
    {name_and_params, value} = ContentLines.split_value(line)
    parts = parse(value)

    with {:ok, followed} <- follow_days(parts, days),
         {:ok, followed} <- follow_until(followed, shift, days, opts) do
      # Unchanged, the line goes back exactly as the server wrote it.
      if followed == parts,
        do: {:ok, line},
        else: {:ok, name_and_params <> ":" <> join(followed)}
    end
  end

  defp follow_days(parts, days) do
    cond do
      has_any?(parts, @time_parts) -> pinned()
      days == 0 -> {:ok, parts}
      has_any?(parts, @day_parts) -> pinned()
      not has_any?(parts, ["BYDAY"]) -> {:ok, parts}
      true -> rotate(parts, days)
    end
  end

  defp follow_until(parts, shift, days, opts) do
    until = part(parts, "UNTIL")

    if is_nil(until) or Keyword.get(opts, :keep_until, false) do
      {:ok, parts}
    else
      with {:ok, moved} <- Shift.shift_bound(until, shift, days, Keyword.get(opts, :zone)),
           do: {:ok, put_part(parts, "UNTIL", moved)}
    end
  end

  defp rotate(parts, days) do
    weekdays = parts |> part("BYDAY") |> String.upcase() |> String.split(",", trim: true)

    if rotatable?(parts, weekdays) and not crosses_week?(parts, weekdays, days) do
      rotated = Enum.map_join(weekdays, ",", &rotate_weekday(&1, days))
      {:ok, put_part(parts, "BYDAY", rotated)}
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
