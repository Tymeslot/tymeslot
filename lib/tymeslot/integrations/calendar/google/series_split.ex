defmodule Tymeslot.Integrations.Calendar.Google.SeriesSplit do
  @moduledoc """
  The two writes that split a Google recurring event in two at one of its
  occurrences, for an edit of that occurrence and every one after it (see
  `Recurrence.SeriesSplit`). Pure data: the provider reads the master, and
  writes what this builds.

    * **The tail** is inserted as a new event: the master's own fields, with
      `start` and `end` at the slot in the master's `timeZone` and the length
      the master has, and the master's `recurrence` lines from the slot on:
      the `RRULE` with its `COUNT` less the occurrences before the slot (an
      `UNTIL` kept as it is), and the `EXDATE` and `RDATE` values at or
      after the slot. The edit is then applied to it by `Google.SeriesPatch`
      as an edit of every occurrence, so a move, a new rule and new fields
      land on the tail alone.
    * **The head** is the master patched with its `recurrence` alone: the
      `RRULE` ends just before the slot, its `UNTIL` in the value type RFC
      5545 requires (the day before for an all-day series, the UTC instant a
      second before for a timed one), and the `EXDATE` and `RDATE` values at
      or after the slot go.

  The tail is built from the master as `Google.CreatableEvent` makes any
  event creatable: what Google assigns or manages itself is not copied, and
  a conference is copied as the join details it has, so the tail's
  occurrences keep the series' Meet link.

  Occurrences edited on their own in Google are separate events that name
  the master. Those from the slot on are not carried to the tail: Google
  drops them once the master's rule no longer makes their slot.
  """

  alias Tymeslot.Integrations.Calendar.Google.CreatableEvent
  alias Tymeslot.Integrations.Calendar.Google.SeriesPatch
  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Document
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Split
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesSplit
  alias Tymeslot.Utils.DateTimeUtils

  @slot_lists ["EXDATE", "RDATE"]

  @typedoc """
  The tail's body for `events.insert`, and the master's for `events.patch`.
  """
  @type halves :: %{tail: map(), head: map()}

  @doc """
  The halves `master`, the series' master as Google returned it, is split
  into at `edit.slot` (see `Recurrence.SeriesSplit.slot/0`), with the edit
  (see `Recurrence.SeriesMove.edit/0`) applied to the tail.

  `:first_occurrence` when nothing of the series comes before the slot: the
  edit is of every occurrence, and is written as one.
  """
  @spec build(map(), SeriesMove.edit()) :: {:ok, halves()} | :first_occurrence | {:error, term()}
  def build(master, %{slot: slot} = edit) do
    lines = master["recurrence"] || []

    with {:ok, timing, zone} <- SeriesPatch.master_timing(master),
         {:ok, rule} <- find_rule(lines),
         {:ok, slot} <- SeriesSplit.slot_wall(slot, timing, zone),
         :ok <- SeriesSplit.ensure_occurrences_before(timing, slot),
         {:ok, before} <- count_before(rule, timing, slot, zone),
         {:ok, head, tail_lines} <- divide(lines, %{slot: slot, zone: zone, before: before}),
         tail = tail(master, timing, %{slot: slot, zone: zone}, tail_lines),
         {:ok, patch} <- SeriesPatch.build(tail, edit) do
      {:ok, %{tail: Map.merge(tail, patch), head: %{"recurrence" => head}}}
    end
  end

  defp find_rule(lines) do
    case ContentLines.find("RRULE", lines) do
      nil -> {:error, :not_recurring}
      line -> {:ok, line}
    end
  end

  # Only a COUNT needs the occurrences before the slot; an UNTIL is kept.
  defp count_before(rule, timing, slot, zone) do
    if Map.has_key?(RRule.parse(rule), :count),
      do: SeriesSplit.count_before(rule, timing, slot, zone),
      else: {:ok, 0}
  end

  # The master's recurrence lines, as the head keeps them and as the tail
  # takes them.
  defp divide(lines, split) do
    with {:ok, head} <- map_lines(lines, &head_line(&1, split)),
         {:ok, tail} <- map_lines(lines, &tail_line(&1, split)),
         do: {:ok, head, tail}
  end

  defp head_line(line, split) do
    case ContentLines.property_name(line) do
      "RRULE" -> {:ok, RRule.end_before(line, SeriesSplit.boundary(split.slot, split.zone))}
      name when name in @slot_lists -> keep_values(line, split, :before)
      _other -> {:ok, line}
    end
  end

  defp tail_line(line, split) do
    case ContentLines.property_name(line) do
      "RRULE" -> {:ok, RRule.reduce_count(line, split.before)}
      name when name in @slot_lists -> keep_values(line, split, :from)
      _other -> {:ok, line}
    end
  end

  # The slot lists hold the same values as a CalDAV series' properties, and
  # are divided by the same rule; a line left with none goes.
  defp keep_values(line, split, side) do
    wall = with %Date{} = date <- split.slot, do: NaiveDateTime.new!(date, ~T[00:00:00])
    Split.keep_values(line, wall, {split.zone, split.zone}, side)
  end

  defp map_lines(lines, fun) do
    with {:ok, mapped} <- Document.map_ok(lines, fun),
         do: {:ok, Enum.reject(mapped, &(&1 == :drop))}
  end

  # --- The tail ---

  defp tail(master, timing, split, lines) do
    {start, finish} = SeriesSplit.at_slot(timing, split.slot)

    master
    |> CreatableEvent.from_event()
    |> Map.merge(%{
      "start" => timing_value(start, split.zone),
      "end" => timing_value(finish, split.zone),
      "recurrence" => lines
    })
  end

  defp timing_value(%Date{} = date, _zone), do: %{"date" => Date.to_iso8601(date)}

  # With its offset, as Google returns it, so `SeriesPatch` reads the tail as
  # it reads a master.
  defp timing_value(wall, zone) do
    instant =
      DateTimeUtils.create_datetime_safe(
        NaiveDateTime.to_date(wall),
        NaiveDateTime.to_time(wall),
        zone
      )

    %{"dateTime" => DateTime.to_iso8601(instant), "timeZone" => zone}
  end
end
