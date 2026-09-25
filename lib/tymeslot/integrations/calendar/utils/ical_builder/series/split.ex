defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series.Split do
  @moduledoc """
  Splitting a recurring event stored as one CalDAV resource in two at one of
  its occurrences, for an edit of that occurrence and every one after it.
  The public entry points, and the rules they follow, are
  `ICalBuilder.Series.split/5` and `ICalBuilder.Series.truncate/3`; this
  module is their implementation.

  The split is made at the edited occurrence's slot, its original start on
  the wall clock of the series' zone (the occurrence key). Every value is
  compared with it on that wall clock, whatever form it is written in.

  The tail is a series whose first occurrence is the slot, so an edit of
  "this and every following occurrence" of the original is an edit of every
  occurrence of the tail. It is carried out by `Series.Master` on the tail
  alone, which moves the tail's exceptions, overrides and rule with it and
  refuses exactly the edits it refuses for the whole series.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Scheduling
  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Document
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Master
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Shift
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Timing
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Utils.DateTimeUtils

  # The master's lines that list slots of the series, divided between the
  # two halves value by value.
  @slot_lists ["EXDATE", "RDATE"]

  @typedoc "The two resources a series is split into."
  @type halves :: %{head: String.t(), tail: String.t(), tail_uid: String.t()}

  @doc "See `ICalBuilder.Series.split/5`."
  @spec split(String.t(), String.t(), map(), String.t() | nil, Scheduling.mode()) ::
          {:ok, halves()} | :first_occurrence | {:error, term()}
  def split(document, key, changes, timezone, mode) do
    components = Document.components(document)
    uid = Format.generate_uid()

    with {:ok, plan} <- plan(components, key, timezone),
         :ok <- ensure_occurrences_before(plan),
         {:ok, head} <- head(components, plan),
         {:ok, tail} <- tail(components, plan, uid),
         {:ok, tail} <- Document.serialise(tail),
         {:ok, tail} <- Master.edit(tail, key, changes, timezone, mode) do
      {:ok, %{head: head, tail: tail, tail_uid: uid}}
    end
  end

  @doc "See `ICalBuilder.Series.truncate/3`."
  @spec truncate(String.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def truncate(document, key, timezone) do
    components = Document.components(document)

    with {:ok, plan} <- plan(components, key, timezone),
         :ok <- ensure_occurrences_before(plan) do
      head(components, plan)
    else
      :first_occurrence -> {:error, :first_occurrence}
      error -> error
    end
  end

  # --- Where the series is split ---

  # Everything both halves are read against: the master's DTSTART and rule,
  # the slot on the series' wall clock, how many occurrences the rule makes
  # before it, and the end the head's rule takes.
  defp plan(components, key, timezone) do
    zones = {Document.series_zone(components, timezone), timezone}

    with {:ok, {:vevent, master}} <- find_master(components),
         properties = Document.properties(master),
         dtstart = ContentLines.find("DTSTART", properties),
         {:ok, rule} <- find_rule(properties),
         {:ok, slot} <- read(Shift.key_wall(key)),
         {:ok, start} <- read(Shift.wall(dtstart, elem(zones, 0), timezone)) do
      {:ok,
       %{
         dtstart: dtstart,
         slot: slot,
         shift: NaiveDateTime.diff(slot, start),
         zones: zones,
         before: count_before(dtstart, rule, start, slot, elem(zones, 0)),
         boundary: boundary(dtstart, slot, elem(zones, 0))
       }}
    end
  end

  defp find_master(components) do
    case Enum.find(components, &Document.master?/1) do
      nil -> {:error, :master_not_found}
      master -> {:ok, master}
    end
  end

  defp find_rule(properties) do
    case ContentLines.find("RRULE", properties) do
      nil -> {:error, :not_recurring}
      line -> {:ok, line |> ContentLines.split_value() |> elem(1)}
    end
  end

  defp read({:ok, value}), do: {:ok, value}
  defp read(:error), do: {:error, :unreadable_timing}

  # Nothing of the series comes before the slot: the edit is of every
  # occurrence, which the caller writes as one.
  defp ensure_occurrences_before(%{before: 0}), do: :first_occurrence
  defp ensure_occurrences_before(_plan), do: :ok

  # How many occurrences the rule makes before the slot, counted the way the
  # sync expands it (`RecurrenceExpander`), so the tail's COUNT and the
  # head's end agree with what the sync shows. Exceptions are not left out:
  # RFC 5545 counts an excluded occurrence towards COUNT all the same.
  defp count_before(dtstart, rule, start, slot, zone) do
    first = if Timing.date?(dtstart), do: NaiveDateTime.to_date(start), else: instant(start, zone)
    last = slot |> instant(zone) |> DateTime.add(-1, :second)

    %{start_time: first, end_time: first, recurrence_rule: rule}
    |> RecurrenceExpander.expand(first, last)
    |> length()
  end

  # The head's rule ends before the slot, in the value type of DTSTART
  # (RFC 5545 §3.3.10, see `RRule.end_before/2`).
  defp boundary(dtstart, slot, zone) do
    cond do
      Timing.date?(dtstart) -> NaiveDateTime.to_date(slot)
      floating?(dtstart) -> slot
      true -> instant(slot, zone)
    end
  end

  defp floating?(dtstart) do
    {name_and_params, value} = ContentLines.split_value(dtstart)

    not String.contains?(String.upcase(name_and_params), ";TZID=") and
      not String.ends_with?(String.trim(value), ["Z", "z"])
  end

  # A wall clock on the series' clock as the instant the sync reads it as; a
  # floating or UTC series has no zone and is read in UTC.
  defp instant(wall, zone) do
    DateTimeUtils.create_datetime_safe(
      NaiveDateTime.to_date(wall),
      NaiveDateTime.to_time(wall),
      zone || "Etc/UTC"
    )
  end

  # --- The head: the original resource, ended before the slot ---

  defp head(components, plan) do
    components
    |> Enum.filter(&(not vevent?(&1) or not from_slot?(&1, plan)))
    |> Document.map_ok(fn
      {:vevent, items} = vevent ->
        if Document.master?(vevent),
          do: map_items(items, &head_line(&1, plan)),
          else: {:ok, vevent}

      line ->
        {:ok, line}
    end)
    |> then(fn
      {:ok, components} -> Document.serialise(components)
      error -> error
    end)
  end

  defp head_line(line, plan) do
    case ContentLines.property_name(line) do
      "RRULE" -> {:ok, map_value(line, &RRule.end_before(&1, plan.boundary))}
      name when name in @slot_lists -> keep_values(line, plan, :before)
      _other -> {:ok, line}
    end
  end

  # --- The tail: a new resource, starting at the slot ---

  defp tail(components, plan, uid) do
    components
    |> Enum.filter(&(not vevent?(&1) or Document.master?(&1) or from_slot?(&1, plan)))
    |> Document.map_ok(fn
      {:vevent, items} = vevent ->
        line_fun =
          if Document.master?(vevent),
            do: &tail_master_line(&1, plan, uid),
            else: &{:ok, put_uid(&1, uid)}

        map_items(items, line_fun)

      line ->
        {:ok, line}
    end)
  end

  defp tail_master_line(line, plan, uid) do
    case ContentLines.property_name(line) do
      "UID" -> {:ok, put_uid(line, uid)}
      "DTSTART" -> Shift.shift_line(line, plan.shift)
      "DTEND" -> Shift.shift_line(line, plan.shift)
      "RRULE" -> {:ok, map_value(line, &RRule.reduce_count(&1, plan.before))}
      name when name in @slot_lists -> keep_values(line, plan, :from)
      _other -> {:ok, line}
    end
  end

  defp put_uid(line, uid) do
    if ContentLines.property_name(line) == "UID", do: "UID:" <> uid, else: line
  end

  # --- Dividing the slots ---

  defp vevent?(component), do: match?({:vevent, _items}, component)

  # Whether an override replaces an occurrence at or after the slot. The
  # master itself is never "from the slot": both halves keep a master.
  defp from_slot?({:vevent, items} = vevent, plan) do
    {zone, _timezone} = plan.zones

    with false <- Document.master?(vevent),
         line when is_binary(line) <-
           ContentLines.find("RECURRENCE-ID", Document.properties(items)),
         {_name, value} = ContentLines.split_value(line),
         key when is_binary(key) <- ICalNormaliser.occurrence_key(value, zone),
         {:ok, wall} <- Shift.key_wall(key) do
      NaiveDateTime.compare(wall, plan.slot) != :lt
    else
      _master_or_unreadable -> false
    end
  end

  # Keeps the values of an EXDATE or RDATE line on one side of the slot,
  # `:before` it for the head and `:from` it on for the tail; a line left
  # with none is dropped.
  defp keep_values(line, plan, side) do
    {name_and_params, values} = ContentLines.split_value(line)
    {zone, timezone} = plan.zones

    kept =
      values
      |> String.split(",")
      |> Enum.filter(fn value ->
        # A period (RDATE) is placed by its start.
        start = value |> String.split("/") |> hd()

        case Shift.wall(name_and_params <> ":" <> start, zone, timezone) do
          {:ok, wall} -> NaiveDateTime.compare(wall, plan.slot) == :lt == (side == :before)
          # Unreadable here is unreadable to the sync too: it stays with the
          # original resource rather than being carried.
          :error -> side == :before
        end
      end)

    case kept do
      [] -> {:ok, :drop}
      kept -> {:ok, name_and_params <> ":" <> Enum.join(kept, ",")}
    end
  end

  defp map_value(line, fun) do
    {name_and_params, value} = ContentLines.split_value(line)
    name_and_params <> ":" <> fun.(value)
  end

  # Maps the property lines of a VEVENT's items through `fun`, leaving its
  # subcomponents as they are; a line mapped to `:drop` is left out.
  defp map_items(items, fun) do
    items
    |> Document.map_ok(fn
      line when is_binary(line) -> fun.(line)
      subcomponent -> {:ok, subcomponent}
    end)
    |> then(fn
      {:ok, items} -> {:ok, {:vevent, Enum.reject(items, &(&1 == :drop))}}
      error -> error
    end)
  end
end
