defmodule Tymeslot.Integrations.Calendar.Recurrence.SeriesSplit do
  @moduledoc """
  Splitting a Google or Outlook recurring event in two at one of its
  occurrences, for an edit of that occurrence and every one after it: what
  both providers share. `Google.SeriesSplit` and `Outlook.SeriesSplit` build
  each provider's bodies from it, and the providers write them with
  `write/3`.

  The split is made at the edited occurrence's *slot*: its original start,
  where the series put it before anyone moved it on its own, which is what
  the series' rule and exceptions name. It is read on the wall clock of the
  master's own zone, as every other value of the series is (see
  `Recurrence.SeriesMove`), so a slot after a DST change is compared with a
  master before it on one clock.

  The occurrences from the slot on become a new series, the tail, whose
  first occurrence is the slot; the original master, the head, is ended just
  before it. An edit of "this and every following occurrence" of the
  original is then an edit of every occurrence of the tail, which each
  provider's `SeriesPatch` applies to the tail's body before it is written.
  An edit of the first occurrence leaves nothing for the head, and is an edit
  of every occurrence (`:first_occurrence`).

  The CalDAV equivalent is `ICalBuilder.Series.split/5`, which works on the
  iCalendar lines the series is stored in; the occurrences before the slot
  are counted the same way for both (`RecurrenceExpander.count_before/3`).
  """

  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Utils.DateTimeUtils

  require Logger

  # The rule parts `RecurrenceExpander` steps through as the providers do.
  # A COUNT over any other part (BYMONTHDAY, BYSETPOS, an ordinal BYDAY)
  # would be counted wrongly, and the tail would end on another date.
  @countable_parts ~w(FREQ INTERVAL COUNT UNTIL BYDAY WKST)

  @typedoc """
  An occurrence's original start: the day of an all-day series, or the
  instant of a timed one.
  """
  @type slot :: Date.t() | DateTime.t()

  @doc """
  `slot` on the wall clock of `zone`, the zone of the master whose timing is
  `timing` (see `Recurrence.SeriesMove.timing/0`): a date for an all-day
  series, a wall clock for a timed one. A timed series in a zone that cannot
  be read is `{:error, :unreadable_timing}`.
  """
  @spec slot_wall(slot(), tuple(), String.t() | nil) ::
          {:ok, Date.t() | NaiveDateTime.t()} | {:error, :unreadable_timing}
  def slot_wall(%Date{} = slot, {%Date{}, _finish}, _zone), do: {:ok, slot}

  def slot_wall(%DateTime{} = slot, {%Date{}, _finish}, zone) do
    with {:ok, local} <- local(slot, zone || "Etc/UTC"), do: {:ok, NaiveDateTime.to_date(local)}
  end

  def slot_wall(%DateTime{} = slot, {%NaiveDateTime{}, _finish}, zone) when is_binary(zone),
    do: local(slot, zone)

  def slot_wall(_slot, _timing, _zone), do: {:error, :unreadable_timing}

  defp local(instant, zone) do
    case DateTime.shift_zone(instant, zone) do
      {:ok, local} -> {:ok, local |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)}
      {:error, _reason} -> {:error, :unreadable_timing}
    end
  end

  @doc """
  `:ok` when the series has an occurrence before `slot`, and
  `:first_occurrence` when it has none: the master's start is its first
  occurrence on both providers.
  """
  @spec ensure_occurrences_before(tuple(), Date.t() | NaiveDateTime.t()) ::
          :ok | :first_occurrence
  def ensure_occurrences_before({%Date{} = start, _finish}, %Date{} = slot),
    do: first_or_not(Date.compare(start, slot))

  def ensure_occurrences_before({start, _finish}, slot),
    do: first_or_not(NaiveDateTime.compare(start, slot))

  defp first_or_not(:lt), do: :ok
  defp first_or_not(_same_or_later), do: :first_occurrence

  @doc """
  The master's `timing` moved to start at `slot`, lasting as long on the
  wall clock: the tail's first occurrence.
  """
  @spec at_slot(tuple(), Date.t() | NaiveDateTime.t()) :: tuple()
  def at_slot({%Date{} = start, finish}, %Date{} = slot),
    do: {slot, Date.add(finish, Date.diff(slot, start))}

  def at_slot({start, finish}, slot),
    do: {slot, NaiveDateTime.add(finish, NaiveDateTime.diff(slot, start))}

  @doc """
  Where the head's rule ends: the slot's day for an all-day series, and for
  a timed one the instant the slot's wall clock is in `zone`, which
  `RRule.end_before/2` turns into the UTC `UNTIL` RFC 5545 requires.
  """
  @spec boundary(Date.t() | NaiveDateTime.t(), String.t() | nil) :: Date.t() | DateTime.t()
  def boundary(%Date{} = slot, _zone), do: slot
  def boundary(slot, zone), do: instant(slot, zone)

  @doc """
  How many occurrences `rule` makes before `slot`, from the start of
  `timing`, on the wall clock of `zone`. A rule with parts the count cannot
  follow is `{:error, :unsupported_rule}`, rather than a tail that ends on
  another date than the original did.
  """
  @spec count_before(String.t(), tuple(), Date.t() | NaiveDateTime.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, :unsupported_rule}
  def count_before(rule, {start, _finish}, slot, zone) do
    if countable?(rule),
      do: {:ok, RecurrenceExpander.count_before(rule, point(start, zone), point(slot, zone))},
      else: {:error, :unsupported_rule}
  end

  defp point(%Date{} = date, _zone), do: date
  defp point(wall, zone), do: instant(wall, zone)

  defp instant(wall, zone) do
    DateTimeUtils.create_datetime_safe(
      NaiveDateTime.to_date(wall),
      NaiveDateTime.to_time(wall),
      zone || "Etc/UTC"
    )
  end

  # `RecurrenceExpander` counts weeks from Monday, so a rule that repeats on
  # several days every few weeks from another week start is counted only
  # when that makes no difference.
  defp countable?(rule) do
    parts =
      rule
      |> String.replace_prefix("RRULE:", "")
      |> String.split(";", trim: true)
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [name, value] -> {String.upcase(name), String.upcase(value)}
          [name] -> {String.upcase(name), ""}
        end
      end)

    days = parts |> Map.get("BYDAY", "") |> String.split(",", trim: true)

    Enum.all?(Map.keys(parts), &(&1 in @countable_parts)) and
      not Enum.any?(days, &String.match?(&1, ~r/\d/)) and
      (Map.get(parts, "WKST", "MO") == "MO" or Map.get(parts, "INTERVAL", "1") == "1" or
         length(days) < 2)
  end

  @doc """
  Writes a split: `create` makes the tail, then `truncate` ends the master.
  The tail comes first, so the following occurrences are never off the
  calendar. If the master cannot be ended, `discard` deletes the tail again
  and the master's failure is returned; if the tail cannot be made, nothing
  else is written. Answers the tail as `create` returned it.
  """
  @spec write((-> {:ok, map()} | term()), (-> {:ok, term()} | term()), (map() -> term())) ::
          {:ok, map()} | term()
  def write(create, truncate, discard) do
    with {:ok, tail} <- create.() do
      case truncate.() do
        {:ok, _master} ->
          {:ok, tail}

        failure ->
          discard_tail(discard, tail)
          failure
      end
    end
  end

  defp discard_tail(discard, tail) do
    case discard.(tail) do
      :ok ->
        :ok

      other ->
        Logger.warning("Could not delete the new half of a series whose original was not ended",
          reason: inspect(other)
        )
    end
  end
end
