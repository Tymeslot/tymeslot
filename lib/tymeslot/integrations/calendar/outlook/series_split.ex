defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesSplit do
  @moduledoc """
  The two writes that split an Outlook recurring event in two at one of its
  occurrences, for an edit of that occurrence and every one after it (see
  `Recurrence.SeriesSplit`). Pure data: the provider reads the series
  master, and writes what this builds.

  Graph keeps a series' end in its `recurrence.range`, read as local dates in
  the zone the series was created in (`originalStartTimeZone`):

    * **The tail** is created as a new event: the master's own fields, with
      `start` and `end` at the slot's wall clock in that zone, labelled with
      it, and the length the master has; the master's pattern; and its range
      from the slot's date on (`startDate`), a `numbered` range with its
      `numberOfOccurrences` less the occurrences before the slot, an
      `endDate` or `noEnd` range as it was. The edit is then applied to it by
      `Outlook.SeriesPatch` as an edit of every occurrence, so a move, a new
      rule and new fields land on the tail alone.
    * **The head** is the master patched with its `recurrence` alone: the
      same pattern, and an `endDate` range ending on the day before the
      slot's date.

  The tail is built from the master as `Outlook.CreatableEvent` makes any
  event creatable: its writable fields only, without what Graph assigns or
  manages itself and without the series' online meeting, since creating an
  event with one asks Teams for a new meeting. The join details the
  organiser sees in the body are copied with it, and lead to the original
  meeting, which the head keeps.

  Occurrences edited or deleted on their own are not in the master's
  `recurrence`, so these bodies make the tail's occurrences all plain, and
  Graph drops the master's own exceptions from the slot on once its range
  ends before them. The provider carries them to the tail once it is
  written (`Outlook.SeriesExceptions`).
  """

  alias Tymeslot.Integrations.Calendar.Outlook.CreatableEvent
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesPatch
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesSplit

  @typedoc "The tail's body for a create, and the master's for a patch."
  @type halves :: %{tail: map(), head: map()}

  @doc """
  The halves `master`, the series master as Graph returned it (in UTC), is
  split into at `edit.slot` (see `Recurrence.SeriesSplit.slot/0`), with the
  edit (see `Recurrence.SeriesMove.edit/0`) applied to the tail.

  `:first_occurrence` when nothing of the series comes before the slot: the
  edit is of every occurrence, and is written as one.
  """
  @spec build(map(), SeriesMove.edit()) :: {:ok, halves()} | :first_occurrence | {:error, term()}
  def build(master, %{slot: slot} = edit) do
    with {:ok, timing, {zone, label}} <- SeriesPatch.master_timing(master),
         {:ok, recurrence} <- find_recurrence(master),
         {:ok, slot} <- SeriesSplit.slot_wall(slot, timing, zone),
         :ok <- ensure_occurrences_before(recurrence, timing, slot, zone),
         {:ok, range} <- tail_range(recurrence, timing, slot, zone),
         tail = tail(master, timing, slot, label, %{recurrence | "range" => range}),
         {:ok, patch} <- SeriesPatch.build(tail, edit) do
      {:ok,
       %{
         tail: tail |> Map.merge(patch) |> Map.delete("originalStartTimeZone"),
         head: %{"recurrence" => head_recurrence(recurrence, slot)}
       }}
    end
  end

  defp find_recurrence(%{"recurrence" => %{"pattern" => %{}, "range" => %{}} = recurrence}),
    do: {:ok, recurrence}

  defp find_recurrence(_master), do: {:error, :not_recurring}

  @doc """
  How many occurrences an Outlook series repeating by `rule` from
  `start_date` has before `slot_date`, when its pattern is an absolute
  monthly or yearly one, counted as Graph counts it: one date in every
  period, a day the month lacks on its last day (see `count_before/4`
  below). `:not_absolute` for any other rule, which RFC 5545 counts as
  Graph does.

  A series on the 31st read from Outlook carries a rule with no
  `BYMONTHDAY` (`RecurrenceConverter.outlook_to_rrule/1`), which RFC 5545
  would step on the 31st alone, skipping every shorter month that Graph
  gives an occurrence on its last day.
  """
  @spec absolute_count_before(String.t(), Date.t(), Date.t()) ::
          {:ok, non_neg_integer()} | :not_absolute
  def absolute_count_before(rule, %Date{} = start_date, %Date{} = slot_date) do
    with {:ok, parsed} <- RRule.parse(rule),
         {:ok, pattern} <- absolute_pattern(parsed, start_date),
         {:ok, nth_date} <- absolute_dates(pattern) do
      {:ok, count_dates_before(nth_date, start_date, slot_date)}
    else
      _other -> :not_absolute
    end
  end

  defp absolute_pattern(%RRule{by_day: nil, by_set_pos: nil, other: []} = rule, start) do
    case {rule.freq, rule.by_month, rule.by_month_day} do
      {:monthly, nil, day} ->
        {:ok, absolute("absoluteMonthly", rule, %{"dayOfMonth" => day_of(day, start)})}

      {:yearly, month, day} when month == nil or length(month) == 1 ->
        month = if month, do: hd(month), else: start.month

        {:ok,
         absolute("absoluteYearly", rule, %{"dayOfMonth" => day_of(day, start), "month" => month})}

      _other ->
        :not_absolute
    end
  end

  defp absolute_pattern(_rule, _start), do: :not_absolute

  defp absolute(type, rule, fields),
    do: Map.merge(%{"type" => type, "interval" => rule.interval}, fields)

  defp day_of(nil, start), do: start.day
  defp day_of([day], _start) when day > 0, do: day
  defp day_of(_days, _start), do: nil

  # --- The ranges ---

  defp tail_range(%{"range" => range} = recurrence, timing, slot, zone) do
    from_slot = Map.put(range, "startDate", Date.to_iso8601(date_of(slot)))

    case range do
      %{"type" => "numbered", "numberOfOccurrences" => total} when is_integer(total) ->
        with {:ok, before} <- count_before(recurrence, timing, slot, zone),
             do: {:ok, Map.put(from_slot, "numberOfOccurrences", max(total - before, 1))}

      _end_date_or_none ->
        {:ok, from_slot}
    end
  end

  # Graph counts only the dates its pattern makes, so a master whose start is
  # off the pattern (a Monday-and-Wednesday series created on a Tuesday
  # through the API, or a monthly one on the 10th that starts on the 5th) does
  # not have that start as an occurrence: its first occurrence is the
  # pattern's first date, and `numberOfOccurrences` does not include the
  # start.
  #
  # An absolute monthly or yearly pattern is counted as Graph counts it: one
  # date per period, on the pattern's day (and month), from the start's
  # period on. An RRULE cannot stand in for it, because the converter keeps
  # no BYMONTHDAY or BYMONTH, so it would step on the start's own day, and RFC
  # 5545 skips the months without that day (a start on the 31st skips every
  # 30-day month and February) where Graph has a pattern date in each.
  #
  # Any other pattern follows its RRULE, which RFC 5545 always starts with
  # the start, so a start off the pattern comes off again here.
  defp count_before(%{"pattern" => pattern} = recurrence, {start, _finish} = timing, slot, zone) do
    case absolute_dates(pattern) do
      {:ok, nth_date} ->
        {:ok, count_dates_before(nth_date, date_of(start), date_of(slot))}

      :not_absolute ->
        count_by_rule(recurrence, timing, slot, zone)
    end
  end

  defp count_by_rule(
         %{"pattern" => pattern, "range" => range},
         {start, _finish} = timing,
         slot,
         zone
       ) do
    with {:ok, rule} <- rule(pattern, range),
         {:ok, count} <- SeriesSplit.count_before(rule, timing, slot, zone) do
      {:ok, if(on_pattern?(pattern, start), do: count, else: count - 1)}
    end
  end

  # The pattern date of the nth period counted from the start's, for an
  # absolute monthly or yearly pattern. A day of the month a month does not
  # have falls on its last day.
  defp absolute_dates(%{"type" => "absoluteMonthly", "dayOfMonth" => day} = pattern)
       when is_integer(day) do
    step = interval(pattern)

    {:ok,
     fn start, n ->
       month_index = start.year * 12 + start.month - 1 + n * step
       clamped_date(div(month_index, 12), rem(month_index, 12) + 1, day)
     end}
  end

  defp absolute_dates(
         %{"type" => "absoluteYearly", "dayOfMonth" => day, "month" => month} = pattern
       )
       when is_integer(day) and is_integer(month) do
    step = interval(pattern)
    {:ok, fn start, n -> clamped_date(start.year + n * step, month, day) end}
  end

  defp absolute_dates(_pattern), do: :not_absolute

  defp interval(%{"interval" => interval}) when is_integer(interval) and interval > 0,
    do: interval

  defp interval(_pattern), do: 1

  defp clamped_date(year, month, day) do
    first = Date.new!(year, month, 1)
    %{first | day: min(day, Date.days_in_month(first))}
  end

  # The pattern dates on or after the start and before the slot's date.
  defp count_dates_before(nth_date, start_date, slot_date) do
    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&nth_date.(start_date, &1))
    |> Stream.take_while(&(Date.compare(&1, slot_date) == :lt))
    |> Enum.count(&(Date.compare(&1, start_date) != :lt))
  end

  # Whether the master's start is a date the pattern itself makes: a weekly
  # pattern's days. A daily pattern makes every day; absolute monthly and
  # yearly patterns are counted without a rule (`absolute_dates/1`).
  defp on_pattern?(%{"type" => "weekly", "daysOfWeek" => days}, start)
       when is_list(days) and days != [] do
    weekday = start |> date_of() |> Calendar.strftime("%A") |> String.downcase()
    weekday in Enum.map(days, &String.downcase/1)
  end

  defp on_pattern?(_pattern, _start), do: true

  defp rule(pattern, range) do
    case SeriesPatch.pattern_rule(pattern, range) do
      {:ok, rule} -> {:ok, rule}
      {:error, _pinned} -> {:error, :unsupported_rule}
    end
  end

  # A slot with no pattern date before it is the series' first occurrence,
  # even when the master's start, off the pattern, comes earlier. A pattern
  # the count cannot follow is judged by the master's start alone.
  defp ensure_occurrences_before(recurrence, timing, slot, zone) do
    with :ok <- SeriesSplit.ensure_occurrences_before(timing, slot) do
      case count_before(recurrence, timing, slot, zone) do
        {:ok, 0} -> :first_occurrence
        _some_or_uncountable -> :ok
      end
    end
  end

  defp head_recurrence(%{"range" => range} = recurrence, slot) do
    ended =
      range
      |> Map.delete("numberOfOccurrences")
      |> Map.merge(%{
        "type" => "endDate",
        "endDate" => slot |> date_of() |> Date.add(-1) |> Date.to_iso8601()
      })

    %{recurrence | "range" => ended}
  end

  # --- The tail ---

  # `originalStartTimeZone` is what `SeriesPatch` reads the tail's zone from;
  # it is not written.
  defp tail(master, timing, slot, label, recurrence) do
    master
    |> CreatableEvent.from_event()
    |> CreatableEvent.put_timing(SeriesSplit.at_slot(timing, slot), label)
    |> Map.merge(%{"recurrence" => recurrence, "originalStartTimeZone" => label})
  end

  defp date_of(%Date{} = date), do: date
  defp date_of(wall), do: NaiveDateTime.to_date(wall)
end
