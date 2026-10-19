defmodule Tymeslot.Integrations.Calendar.Recurrence.Pattern do
  @moduledoc """
  The repeat patterns the calendar grid's editor builds, and how a stored
  rule reads as one.

  A pattern is the option map `RRule.options/2` reads (`:freq`, `:interval`,
  `:by_day`, `:count`, `:until`) with one more key for a monthly or yearly
  pattern, `:on`: `:day` (the start's day of the month, or of the year) or
  `{ordinal, kind}`, the first to fourth (`1..4`) or last (`-1`) Monday to
  Sunday (`:mo` .. `:su`), day, weekday or weekend day of the month. That is
  everything Google and Outlook can express for a series, and what Outlook
  calls a relative pattern.

  ## Anchored to the start

  A pattern always agrees with the series' first start, so the start is
  always an occurrence: the editor offers only the monthly and yearly
  choices the start satisfies (`choices/1`), a yearly pattern stays in the
  start's month, and a weekly one includes the start's weekday. To repeat
  on another day, the organiser moves the start. The counting and moving
  code (`RecurrenceExpander.countable?/1`, `RuleShift`) relies on that.

  ## Read by meaning

  A stored rule is read as the first pattern it is `equivalent?/4` to: the
  same occurrences from the same start, whatever the spelling (an Outlook
  `UNTIL` written as a date, a `BYMONTHDAY` the start implies, days in
  another order, `FREQ=DAILY;BYDAY=...` for a weekly pattern). A rule no
  pattern matches is `:custom`: the editor shows it without editing it, and
  replaces it only when asked to.
  """

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  @type kind :: RRule.weekday() | :day | :weekday | :weekend_day
  @type on :: :day | {1..4 | -1, kind()}
  @type t :: %{
          required(:freq) => RRule.freq(),
          optional(:interval) => pos_integer(),
          optional(:by_day) => [RRule.weekday()],
          optional(:on) => on(),
          optional(:count) => pos_integer(),
          optional(:until) => Date.t()
        }

  @weekdays ~w(mo tu we th fr sa su)a
  @kind_days %{
    day: ~w(mo tu we th fr sa su)a,
    weekday: ~w(mo tu we th fr)a,
    weekend_day: ~w(sa su)a
  }

  # How far ahead two rules are compared, by frequency: enough periods to
  # tell any two patterns here apart, within `RecurrenceExpander`'s cap.
  # Six years hold every month length and every weekday a date can fall on
  # in a month (a fifth weekday, a leap day) more than once.
  @horizon_days %{daily: 366, weekly: 2 * 366, monthly: 6 * 366, yearly: 60 * 366}

  # How many times a series picked to end "after" a number of times repeats
  # before the organiser types one, and so where one picked to end "on" a
  # date ends before they pick one.
  @default_count 10

  # The largest interval or count a pattern takes.
  @max_number 999

  # The longest a period of each frequency can be, in days, and the last
  # date a series can end on.
  @period_days %{daily: 1, weekly: 7, monthly: 31, yearly: 366}
  @last_date ~D[9999-12-31]

  @doc """
  The monthly and yearly choices a series starting on `start_date` can take:
  `:day`, then each `{ordinal, kind}` the date is (the second Tuesday, the
  last Friday, the last weekday...). A yearly pattern takes them in the
  start's month.
  """
  @spec choices(Date.t()) :: [on()]
  def choices(%Date{} = start_date) do
    weekday = Enum.at(@weekdays, Date.day_of_week(start_date) - 1)
    kind = if weekday in @kind_days.weekday, do: :weekday, else: :weekend_day

    [:day] ++
      positions(start_date, &(&1 == weekday), weekday) ++
      positions(start_date, fn _day -> true end, :day, first: false) ++
      positions(start_date, &(&1 in Map.fetch!(@kind_days, kind)), kind)
  end

  @doc """
  `on` for a series starting on `start_date`: as it is when the date is
  that day; else the same kind of day at the position the date is counted
  at from the month's start (the first Wednesday, moved to a second
  Wednesday, is the second Wednesday); else, for a weekday moved to
  another weekday, the date's own weekday at the date's position (the
  second Monday, moved to a Tuesday, is the second Tuesday, and the last
  stays the last where the date is); else the date's own day of the month.
  """
  @spec reanchor(on(), Date.t()) :: on()
  def reanchor(:day, _start_date), do: :day

  def reanchor({ordinal, kind} = on, %Date{} = start_date) do
    choices = choices(start_date)

    cond do
      on in choices -> on
      same = Enum.find(choices, &match?({position, ^kind} when position > 0, &1)) -> same
      kind in @weekdays -> weekday_position(choices, ordinal)
      true -> :day
    end
  end

  defp weekday_position(choices, ordinal) do
    weekday = for {position, day} <- choices, day in @weekdays, do: {position, day}
    last = Enum.find(weekday, &match?({-1, _day}, &1))
    counted = Enum.find(weekday, &match?({position, _day} when position > 0, &1))

    if ordinal == -1 and last, do: last, else: counted || last || :day
  end

  # The ordinals among the month's days of `kind` (`matches?` says which
  # weekdays are of it) that the start is: its count from the month's start
  # when up to four, and last when no later day of the kind follows.
  defp positions(date, matches?, kind, opts \\ []) do
    month_days = Enum.map(1..Date.days_in_month(date), &Date.new!(date.year, date.month, &1))
    of_kind = Enum.filter(month_days, &matches?.(weekday_atom(&1)))
    index = Enum.find_index(of_kind, &(&1 == date))

    first = if Keyword.get(opts, :first, true) and index < 4, do: [{index + 1, kind}], else: []
    last = if index == length(of_kind) - 1, do: [{-1, kind}], else: []
    first ++ last
  end

  defp weekday_atom(date), do: Enum.at(@weekdays, Date.day_of_week(date) - 1)

  @doc """
  The rule `pattern` writes for a series starting on `start_date`, in the
  forms `RRule.build/2` writes (`:all_day` and `:timezone` decide how its
  `UNTIL` is written). `:keep`, the rule being replaced, gives its `WKST`.
  """
  @spec build(t(), Date.t(), keyword()) :: String.t()
  def build(pattern, %Date{} = start_date, opts \\ []) do
    base =
      pattern
      |> Map.take([:freq, :interval, :by_day, :count, :until])
      |> RRule.build(Keyword.take(opts, [:all_day, :timezone]))

    {:ok, rule} = RRule.parse(base)

    rule
    |> put_on(pattern[:freq], Map.get(pattern, :on, :day), start_date)
    |> Map.put(:week_start, week_start(Keyword.get(opts, :keep)))
    |> RRule.format()
  end

  @doc "The largest interval or count a pattern takes, which the editor's inputs offer as their `max`."
  @spec max_number() :: pos_integer()
  def max_number, do: @max_number

  @doc """
  `pattern` repeating every `interval` periods: a number above one, cut to
  `max_number/0`. Anything else (`nil`, one, less) leaves it repeating every
  period.
  """
  @spec put_interval(map(), integer() | nil) :: map()
  def put_interval(pattern, interval) when is_integer(interval) and interval > 1,
    do: Map.put(pattern, :interval, min(interval, @max_number))

  def put_interval(pattern, _every_period), do: pattern

  @doc """
  `pattern` ending after `count` times, cut to `max_number/0`. A count not
  yet given, or not above nought, is `default_count/0`, so an end picked
  before its number is typed holds.
  """
  @spec put_count(map(), integer() | nil) :: map()
  def put_count(pattern, count) when is_integer(count) and count > 0,
    do: Map.put(pattern, :count, min(count, @max_number))

  def put_count(pattern, _not_given), do: Map.put(pattern, :count, @default_count)

  @doc """
  `pattern` ending on `until`. Without a date, it ends on `default_until/2`
  from `start_date`, so an end picked before its date is given holds; with
  neither, it is left without an end.
  """
  @spec put_until(map(), Date.t() | nil, Date.t() | nil) :: map()
  def put_until(pattern, %Date{} = until, _start_date), do: Map.put(pattern, :until, until)

  def put_until(pattern, nil, %Date{} = start_date),
    do: Map.put(pattern, :until, default_until(pattern, start_date))

  def put_until(pattern, nil, nil), do: pattern

  @doc """
  How many times a series ending "after" a number of times repeats until the
  organiser says.
  """
  @spec default_count() :: pos_integer()
  def default_count, do: @default_count

  @doc """
  The date a series ending "on" a date ends until the organiser picks one:
  the day of the `default_count/0`th occurrence of `pattern` from
  `start_date`, so both kinds of end start from the same series.
  """
  @spec default_until(t(), Date.t()) :: Date.t()
  def default_until(pattern, %Date{} = start_date) do
    rule =
      pattern
      |> Map.drop([:until])
      |> Map.put(:count, @default_count)
      |> build(start_date, all_day: true)

    periods = Map.get(pattern, :interval, 1) * (@default_count + 1)
    days = Map.fetch!(@period_days, pattern.freq) * periods

    horizon =
      if Date.diff(@last_date, start_date) > days,
        do: Date.add(start_date, days),
        else: @last_date

    %{start_time: start_date, end_time: start_date, recurrence_rule: rule}
    |> RecurrenceExpander.expand(start_date, horizon)
    |> List.last(%{start_time: start_date})
    |> Map.fetch!(:start_time)
  end

  defp put_on(rule, freq, :day, _start_date) when freq in [:monthly, :yearly], do: rule

  defp put_on(rule, :monthly, on, _start_date), do: Map.merge(rule, position_parts(on))

  defp put_on(rule, :yearly, on, start_date),
    do: rule |> Map.merge(position_parts(on)) |> Map.put(:by_month, [start_date.month])

  defp put_on(rule, _freq, _on, _start_date), do: rule

  defp position_parts({ordinal, weekday}) when weekday in @weekdays,
    do: %{by_day: [{ordinal, iso(weekday)}], by_set_pos: nil}

  defp position_parts({ordinal, kind}),
    do: %{by_day: Enum.map(Map.fetch!(@kind_days, kind), &{nil, iso(&1)}), by_set_pos: [ordinal]}

  defp iso(weekday), do: Enum.find_index(@weekdays, &(&1 == weekday)) + 1

  defp week_start(rule) when is_binary(rule) do
    case RRule.parse(rule) do
      {:ok, parsed} -> parsed.week_start
      :error -> nil
    end
  end

  defp week_start(_rule), do: nil

  @doc """
  The pattern `rule` is, for a series starting at `start` (a `Date` for an
  all-day series, otherwise a `DateTime` in the series' zone): `{:ok, nil}`
  for no rule, `{:ok, pattern}`, or `:custom` for a rule the editor cannot
  build as it is.
  """
  @spec read(String.t() | nil, Date.t() | DateTime.t()) :: {:ok, t() | nil} | :custom
  def read(rule, _start) when rule in [nil, ""], do: {:ok, nil}

  def read(rule, start) do
    with {:ok, %RRule{other: []} = parsed} <- RRule.parse(rule),
         {:ok, candidates} <- candidates(parsed, start) do
      start_date = date_of(start)

      opts = [
        all_day: is_struct(start, Date) and not is_struct(start, DateTime),
        timezone: zone(start)
      ]

      days = horizon_days(candidates, parsed)
      target = occurrences(rule, start, days)

      Enum.find_value(candidates, :custom, fn candidate ->
        built = build(candidate, start_date, [keep: rule] ++ opts)
        if occurrences(built, start, days) == target, do: {:ok, candidate}
      end)
    else
      _not_a_pattern -> :custom
    end
  end

  defp candidates(parsed, start) do
    start_date = date_of(start)
    base = parsed |> RRule.options(timezone: zone(start)) |> Map.drop([:by_day])
    plain_days = for {nil, iso} <- parsed.by_day || [], do: Enum.at(@weekdays, iso - 1)
    start_day = weekday_atom(start_date)

    case {parsed.freq, parsed.by_day, parsed.interval} do
      {:daily, nil, _interval} ->
        {:ok, [base]}

      # Outlook writes a daily rule on some weekdays as the weekly pattern it is.
      {:daily, [_first | _rest], 1} ->
        weekly(%{base | freq: :weekly}, plain_days, start_day)

      {:weekly, nil, _interval} ->
        {:ok, [Map.put(base, :by_day, [start_day])]}

      {:weekly, _by_day, _interval} ->
        weekly(base, plain_days, start_day)

      {freq, _by_day, _interval} when freq in [:monthly, :yearly] ->
        {:ok, Enum.map(choices(start_date), &Map.put(base, :on, &1))}

      _other ->
        :custom
    end
  end

  defp weekly(base, days, start_day) do
    if start_day in days,
      do: {:ok, [Map.put(base, :by_day, Enum.filter(@weekdays, &(&1 in days)))]},
      else: :custom
  end

  @doc """
  The pattern closest to a `:custom` rule, to start replacing it from: the
  pattern it is without the parts the editor cannot build (a `BYHOUR`, say),
  else its frequency, interval and end.
  """
  @spec closest(String.t(), Date.t() | DateTime.t()) :: t() | map()
  def closest(rule, start) do
    with {:ok, %RRule{other: [_first | _rest]} = parsed} <- RRule.parse(rule),
         {:ok, %{} = pattern} <- read(RRule.format(%{parsed | other: []}), start) do
      pattern
    else
      _not_close -> RRule.options(rule, timezone: zone(start))
    end
  end

  @doc """
  Whether two rules make the same occurrences for a series starting at
  `start` (see `read/2`). No rule is equivalent only to no rule.
  """
  @spec equivalent?(String.t() | nil, String.t() | nil, Date.t() | DateTime.t()) :: boolean()
  def equivalent?(a, b, _start) when a in [nil, ""] or b in [nil, ""],
    do: a in [nil, ""] and b in [nil, ""]

  def equivalent?(a, a, _start), do: true

  def equivalent?(a, b, start) do
    with {:ok, rule_a} <- RRule.parse(a),
         {:ok, rule_b} <- RRule.parse(b) do
      days = max(Map.fetch!(@horizon_days, rule_a.freq), Map.fetch!(@horizon_days, rule_b.freq))
      occurrences(a, start, days) == occurrences(b, start, days)
    else
      :error -> false
    end
  end

  # The candidates share a frequency, which may differ from the rule's own
  # (a daily rule read as a weekly pattern): the longer horizon tells both.
  defp horizon_days([candidate | _rest], parsed),
    do: max(Map.fetch!(@horizon_days, candidate.freq), Map.fetch!(@horizon_days, parsed.freq))

  defp horizon_days([], _parsed), do: 0

  defp occurrences(rule, start, days) do
    %{start_time: start, end_time: start, recurrence_rule: rule}
    |> RecurrenceExpander.expand(start, horizon(start, days))
    |> Enum.map(& &1.start_time)
  end

  defp horizon(%DateTime{} = start, days), do: DateTime.add(start, days, :day)
  defp horizon(%Date{} = start, days), do: Date.add(start, days)

  defp date_of(%DateTime{} = start), do: DateTime.to_date(start)
  defp date_of(%Date{} = start), do: start

  defp zone(%DateTime{time_zone: zone}), do: zone
  defp zone(%Date{}), do: nil
end
