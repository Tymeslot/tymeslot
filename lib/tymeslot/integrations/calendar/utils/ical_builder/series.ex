defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series do
  @moduledoc """
  Component-level editing of a recurring event stored as one CalDAV resource.

  On CalDAV a series is a single document: the master `VEVENT`, which carries
  the `RRULE`, plus one override `VEVENT` per occurrence edited on its own,
  each naming the slot it replaces with a `RECURRENCE-ID` (RFC 5545 §3.8.4.4).
  Changing one occurrence of the series therefore means rewriting that
  document.

  `ICalBuilder.Patcher` edits properties inside the master and never touches
  an override. This module works one level up: it adds, edits and removes
  whole `VEVENT`s and the properties that tie them to the master's recurrence
  set (`EXDATE`, `RECURRENCE-ID`), and leaves every other line of the
  document, the `VTIMEZONE` and each `VALARM` included, exactly as the server
  returned it. The document is read and written by `Series.Document`; an
  edit of every occurrence (`edit_master/5`) is carried out by
  `Series.Master`, which moves timing with `Series.Shift` and the rule with
  `Series.RuleShift`, and a split for an edit of one occurrence and every
  following one (`split/5`) by `Series.Split`.

  ## Occurrence keys

  An occurrence is named the way the cache keys it: its original start as a
  wall-clock stamp in the series' own zone, `YYYYMMDDTHHMMSS` for a timed
  series and `YYYYMMDD` for an all-day one (see `ICalNormaliser`). A
  `RECURRENCE-ID` is reduced to that key by `ICalNormaliser.occurrence_key/2`,
  the same rule the sync applies, so an override is recognised here exactly
  when the sync files it over the same occurrence.

  The series' zone is the one its master's `DTSTART` names
  (`ICalBuilder.Timing.zone/2`), as it is for the sync; the zone a caller
  passes in stands in only where the document cannot say (a `TZID` defined
  by the document's `VTIMEZONE` alone, or a resource with no master).
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Scheduling
  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Patcher
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Document
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Master
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Shift
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Split
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Uid
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Timing

  # Where a new EXDATE goes in the master, in order of preference: after the
  # EXDATEs already there, else beside the rule that generates the slot.
  @exdate_anchors ["EXDATE", "RRULE", "RDATE", "DTSTART"]

  # What makes the master a recurrence set rather than one event; an override
  # made from the master leaves them behind (RFC 5545 §3.8.4.4).
  @recurrence_properties ["RRULE", "RDATE", "EXDATE", "EXRULE"]

  # The payload keys an override takes from the series' side rather than from
  # `Patcher`, which would write them as the master's (timing in UTC, a rule,
  # the master's exceptions).
  @series_keys [:start_time, :end_time, :recurrence_rule, :recurrence_exceptions]

  @doc """
  Removes one occurrence from the series in `document`, identified by `key`:
  the occurrence's original start as the wall-clock stamp the cache keys it
  by (`YYYYMMDDTHHMMSS`, or `YYYYMMDD` all-day) in the series' own zone.

  Adds an `EXDATE` for it to the master, in the value type and zone of the
  master's `DTSTART` (RFC 5545 §3.8.5.1), unless one is already there, and
  drops any override `VEVENT` whose `RECURRENCE-ID` names the same slot.
  A UTC `RECURRENCE-ID` is read in the series' zone (see *Occurrence keys*).

  Returns `{:ok, document}`, or `:empty` when nothing of the series would be
  left (a resource holding only that override), which the caller answers by
  deleting the resource.
  """
  @spec exclude_occurrence(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | :empty
  def exclude_occurrence(document, key, timezone)
      when is_binary(document) and is_binary(key) do
    components = Document.components(document)
    zone = Document.series_zone(components, timezone)

    components
    |> Enum.reject(&Document.override_for?(&1, key, zone))
    |> Enum.map(&exclude_from_master(&1, key))
    |> Document.serialise()
  end

  @doc """
  Writes one occurrence of the series in `document` as an override: the
  occurrence named by `key` gets its own `VEVENT` with a `RECURRENCE-ID` in
  the form of the master's `DTSTART`, carrying `changes`. An existing override
  for the slot is edited in place; otherwise one is made from the master (its
  properties minus `RRULE`, `RDATE`, `EXDATE`, with a fresh `DTSTAMP`).

  `changes` uses the provider payload vocabulary (`:summary`, `:description`,
  `:location`, `:start_time`/`:end_time` as UTC `DateTime` or `Date`, ...).
  Timing is written in the form of the master's `DTSTART` (the wall clock in
  its `TZID`, a date, or UTC), never as UTC over a zoned series. Every other
  key is written by `ICalBuilder.Patcher.patch_vevent/3`, in `mode`, exactly
  as it would be on a one-off event; `:recurrence_rule` and
  `:recurrence_exceptions` belong to the series and are ignored.

  An override always states its end as `DTEND` when `changes` carry
  `:end_time`, dropping a `DURATION` it inherited from the master (RFC 5545
  §3.6.1 allows only one): the payload names the occurrence's end as an
  instant, and a `DURATION` recomputed from it would say the same thing less
  directly. Without `:end_time` an edited override keeps whichever it had. A
  new override without `:start_time` and `:end_time` starts at its slot and
  lasts as long as the master, both read from `document` rather than from
  any copy of the occurrence the caller holds; one of the two without the
  other is `{:error, :missing_timing}`.

  Changing the value type of one occurrence (an all-day occurrence in a timed
  series, or the reverse) is `{:error, :value_type_change}`: RFC 5545 allows
  it, but servers disagree about it. A document with no master to copy from
  and no override for the slot is `{:error, :occurrence_not_found}`.

  A UTC `RECURRENCE-ID` is read, and a wall clock placed, in the series'
  zone (see *Occurrence keys*).
  """
  @spec put_override(String.t(), String.t(), map(), String.t() | nil, Scheduling.mode()) ::
          {:ok, String.t()} | {:error, term()}
  def put_override(document, key, changes, timezone, mode \\ :contact)
      when is_binary(document) and is_binary(key) and is_map(changes) do
    components = Document.components(document)
    zone = Document.series_zone(components, timezone)
    index = Enum.find_index(components, &Document.override_for?(&1, key, zone))

    with {:ok, reference} <- reference_start(components, index),
         {:ok, components} <-
           write_override(components, index, reference, key, changes, timezone, mode) do
      Document.serialise(components)
    end
  end

  @doc """
  Edits every occurrence of the series in `document` from the edit of one of
  them, the occurrence named by `key`: its master `VEVENT` takes `changes`,
  and a move of the occurrence moves the whole series with it.

  `changes` uses the payload vocabulary of `put_override/5`, with
  `:start_time` and `:end_time` the edited occurrence's new timing.

    * **Timing.** The series moves by as much as the occurrence did on the
      wall clock of the series' zone: from where it shows now (its override's
      `DTSTART`, else its slot) to `:start_time`. The master's `DTSTART` and
      `DTEND`, its `EXDATE`s and `RDATE`s, and every override's
      `RECURRENCE-ID`, `DTSTART` and `DTEND` move by that amount, each in the
      form it is written in (see `Series.Shift`), so every exception still
      names the slot it did and every override still replaces its own. An
      `:end_time` that changes how long the occurrence lasts gives the master
      that duration, and every override that lasted as long as the master
      (and the edited one) too; other overrides keep their own.
    * **Plain fields** (`:summary`, `:description`, `:location`, `:colour`,
      `:reminders`, `:attendees`) are written to the master by
      `ICalBuilder.Patcher.patch_vevent/3`, in `mode`. Overrides keep their
      own values: they are what the organiser set on those occurrences.
    * **`:recurrence_rule`** replaces the master's `RRULE`, its `UNTIL`
      refitted to the value type and zone of `DTSTART`
      (`Recurrence.RRule.retarget/2`); `EXDATE`s and `RDATE`s stay. A `nil`
      rule is `{:error, :rule_removal}`: that turns the series into one
      event, which is not an edit of every occurrence. Without one, the
      rule follows a move of the series (`Series.RuleShift`): the plain
      weekdays of a weekly or daily `BYDAY` turn by the days it moved, so a
      Monday series moved to Tuesday reads `BYDAY=TU`, and its `UNTIL`
      moves with the series, so the move does not carry the last
      occurrences past the end. A rule the edit states is written as given.
    * `:recurrence_exceptions` belongs to the document and is ignored.

  Refused before anything is written: a change of value type
  (`{:error, :value_type_change}`), a move of a date by part of a day
  (`{:error, :shift_not_whole_days}`), a move the rule cannot follow (an
  ordinal `BYDAY` such as `2MO`, `BYMONTHDAY` and the like for a move to
  another date, a time part for any move, or an every-other-week rule whose
  weekday would cross `WKST`; `{:error, :rule_pins_occurrences}`), a resource with no master
  (`{:error, :master_not_found}`) and timing it cannot read
  (`{:error, :unreadable_timing}`).
  """
  @spec edit_master(String.t(), String.t(), map(), String.t() | nil, Scheduling.mode()) ::
          {:ok, String.t()} | {:error, term()}
  def edit_master(document, key, changes, timezone, mode \\ :contact)
      when is_binary(document) and is_binary(key) and is_map(changes) do
    Master.edit(document, key, changes, timezone, mode)
  end

  @doc """
  Splits the series in `document` in two at the occurrence named by `key`,
  for an edit of that occurrence and every one after it: `changes`, in the
  payload vocabulary of `edit_master/5`, apply to the second half only.

    * **The head** is the original resource, ended just before the slot:
      its `RRULE` takes an `UNTIL` in place of its `COUNT` or `UNTIL`, in the
      value type RFC 5545 §3.3.10 requires (a date for an all-day series, a
      UTC instant for a zoned or UTC one, a floating wall clock for a
      floating one; see `Recurrence.RRule.end_before/2`). Its overrides,
      `EXDATE`s and `RDATE`s at or after the slot go.
    * **The tail** is a new resource under a new `UID` (`tail_uid`): the
      master with its `DTSTART` and `DTEND` moved to the slot, each in its
      own form, its `COUNT` less the occurrences the rule makes before the
      slot (excluded ones included, as RFC 5545 counts them), its `UNTIL`
      kept, and the overrides, `EXDATE`s and `RDATE`s at or after the slot,
      under the new `UID`. Every other line, `VTIMEZONE`, `VALARM`s,
      attendees and `X-` properties included, is copied as written. The
      tail is then edited as a whole by `edit_master/5`, whose rules and
      refusals it follows: the tail is a series whose first occurrence is
      the slot.

  Returns `{:ok, %{head: head, tail: tail, tail_uid: uid}}`, or
  `:first_occurrence` when the rule makes no occurrence before the slot,
  which is an edit of every occurrence (`edit_master/5`). Refused before
  anything is written: a resource with no master (`{:error,
  :master_not_found}`) or no `RRULE` (`{:error, :not_recurring}`), timing
  it cannot read (`{:error, :unreadable_timing}`), a `COUNT` over rule parts
  the occurrences before the slot cannot be counted by
  (`RecurrenceExpander.countable?/1`; `{:error, :unsupported_rule}`), and
  every refusal of `edit_master/5`.
  """
  @spec split(String.t(), String.t(), map(), String.t() | nil, Scheduling.mode()) ::
          {:ok, %{head: String.t(), tail: String.t(), tail_uid: String.t()}}
          | :first_occurrence
          | {:error, term()}
  def split(document, key, changes, timezone, mode \\ :contact)
      when is_binary(document) and is_binary(key) and is_map(changes) do
    Split.split(document, key, changes, timezone, mode)
  end

  @doc """
  The head of `split/5` alone: the series in `document` ended just before
  the occurrence `key` names, with its overrides and exceptions from there
  on removed. What a writer applies to the server's copy when it re-reads
  the series after creating the tail. `{:error, :first_occurrence}` when
  nothing of the series comes before the slot.
  """
  @spec truncate(String.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def truncate(document, key, timezone) when is_binary(document) and is_binary(key) do
    Split.truncate(document, key, timezone)
  end

  @doc """
  The series in `document` under the new identifier `uid`: the `UID` of the
  master and of every override replaced, so the copy is one series apart
  from the original. Every other byte is kept as the server wrote it, its
  folding and line endings included, and so is a subcomponent's own `UID`
  (an alarm's, RFC 9074). A split's tail takes its new `UID` the same way.

  Returns `{:ok, document}`, or `:empty` when `document` holds no `VEVENT`.
  """
  @spec reuid(String.t(), String.t()) :: {:ok, String.t()} | :empty
  def reuid(document, uid) when is_binary(document) and is_binary(uid),
    do: Uid.put(document, uid)

  # --- Writing an override ---

  # The form every timing line of the override takes: the master's DTSTART,
  # or, in a resource holding only overrides, the override's own.
  defp reference_start(components, index) do
    reference =
      case Enum.find(components, &Document.master?/1) do
        {:vevent, items} -> ContentLines.find("DTSTART", Document.properties(items))
        nil when is_integer(index) -> own_start(Enum.at(components, index))
        nil -> nil
      end

    if reference, do: {:ok, reference}, else: {:error, :occurrence_not_found}
  end

  defp own_start({:vevent, items}), do: ContentLines.find("DTSTART", Document.properties(items))

  defp write_override(components, nil, reference, key, changes, timezone, mode) do
    zones = {Document.series_zone(components, timezone), timezone}

    with {:vevent, items} <- Enum.find(components, &Document.master?/1),
         {:ok, items} <- at_slot(items, key, changes, zones),
         {:ok, override} <-
           edit_items(from_master(items, reference, key), reference, changes, timezone, mode) do
      {:ok, insert_after_last_vevent(components, {:vevent, override})}
    end
  end

  defp write_override(components, index, reference, _key, changes, timezone, mode) do
    {:vevent, items} = Enum.at(components, index)

    with {:ok, items} <- edit_items(items, reference, changes, timezone, mode) do
      {:ok, List.replace_at(components, index, {:vevent, items})}
    end
  end

  # The timing a new override starts from. With both ends of the timing in
  # `changes` it is theirs, which `edit_items/5` writes. With neither, the
  # occurrence is where the document puts it: the master's DTSTART and DTEND
  # moved to the slot on the series' wall clock, so it lasts as long as the
  # master does now. One end without the other says nothing whole about
  # where the occurrence goes. Timing arrives as a `Date` or a `DateTime`;
  # anything else is no timing.
  defp at_slot(items, _key, %{start_time: start, end_time: finish}, _zones)
       when is_struct(start) and is_struct(finish),
       do: {:ok, items}

  defp at_slot(items, key, changes, {zone, timezone})
       when not is_map_key(changes, :start_time) and not is_map_key(changes, :end_time) do
    dtstart = ContentLines.find("DTSTART", Document.properties(items))

    with {:ok, slot} <- Shift.key_wall(key),
         {:ok, start} <- Shift.wall(dtstart, zone, timezone) do
      shift = NaiveDateTime.diff(slot, start)

      Document.map_ok(items, fn
        line when is_binary(line) ->
          if ContentLines.property_name(line) in ["DTSTART", "DTEND"],
            do: Shift.shift_line(line, shift),
            else: {:ok, line}

        subcomponent ->
          {:ok, subcomponent}
      end)
    else
      :error -> {:error, :unreadable_timing}
    end
  end

  defp at_slot(_items, _key, _changes, _zones), do: {:error, :missing_timing}

  # The master's own lines stand in for the occurrence's until `changes` say
  # otherwise, named by the slot it replaces; a fresh DTSTAMP comes with the
  # patch.
  defp from_master(items, reference, key) do
    items
    |> Enum.reject(&(is_binary(&1) and ContentLines.property_name(&1) in @recurrence_properties))
    |> Document.insert_after("DTSTART", property_line(slot_for("RECURRENCE-ID", reference, key)))
  end

  defp edit_items(items, reference, changes, timezone, mode) do
    patched =
      items
      |> Enum.flat_map(&Document.item_lines/1)
      |> Patcher.patch_vevent(Map.drop(changes, @series_keys), mode)
      |> Document.collect_items()

    with :ok <- Timing.ensure_value_type(reference, changes) do
      put_timing(patched, reference, changes, timezone)
    end
  end

  defp put_timing(items, reference, changes, timezone) do
    with {:ok, items} <- put_start(items, reference, changes, timezone) do
      put_end(items, reference, changes, timezone)
    end
  end

  defp put_start(items, reference, %{start_time: start}, timezone) when is_struct(start) do
    with {:ok, line} <- Timing.line("DTSTART", start, reference, timezone) do
      {:ok, Document.replace_properties(items, ["DTSTART"], line)}
    end
  end

  defp put_start(items, _reference, _changes, _timezone), do: {:ok, items}

  defp put_end(items, reference, %{end_time: finish} = changes, timezone)
       when is_struct(finish) do
    finish = Timing.end_boundary(finish, Map.get(changes, :start_time))

    with {:ok, line} <- Timing.line("DTEND", finish, reference, timezone) do
      {:ok, Document.replace_properties(items, ["DTEND", "DURATION"], line)}
    end
  end

  defp put_end(items, _reference, _changes, _timezone), do: {:ok, items}

  defp insert_after_last_vevent(components, override) do
    index =
      components
      |> Enum.with_index()
      |> Enum.filter(&match?({{:vevent, _items}, _index}, &1))
      |> List.last()
      |> elem(1)

    List.insert_at(components, index + 1, override)
  end

  # --- Excluding an occurrence ---

  defp exclude_from_master({:vevent, items} = vevent, key) do
    properties = Document.properties(items)

    with nil <- ContentLines.find("RECURRENCE-ID", properties),
         dtstart when is_binary(dtstart) <- ContentLines.find("DTSTART", properties) do
      exdate = exdate_for(dtstart, key)

      if excluded?(properties, exdate),
        do: vevent,
        else: {:vevent, insert_after_anchor(items, property_line(exdate))}
    else
      _override_or_no_start -> vevent
    end
  end

  defp exclude_from_master(line, _key), do: line

  defp exdate_for(dtstart, key), do: slot_for("EXDATE", dtstart, key)

  # RFC 5545 §3.8.5.1, §3.8.4.4: an EXDATE or a RECURRENCE-ID matches an
  # occurrence only in the value type and zone of DTSTART, so it copies
  # DTSTART's parameters as written, and its UTC marker, around the key.
  defp slot_for(name, dtstart, key) do
    {name_and_params, value} = ContentLines.split_value(dtstart)
    params = name_and_params |> String.split(";", parts: 2) |> tl() |> Enum.map_join(&(";" <> &1))
    utc = if String.ends_with?(String.trim(value), ["Z", "z"]), do: "Z", else: ""

    {name <> params, key <> utc}
  end

  defp property_line({name_and_params, value}), do: name_and_params <> ":" <> value

  # An EXDATE may list several values, so the slot counts as excluded when any
  # EXDATE written with the same parameters lists it.
  defp excluded?(properties, {name_and_params, value}) do
    properties
    |> Enum.filter(&(ContentLines.property_name(&1) == "EXDATE"))
    |> Enum.map(&ContentLines.split_value/1)
    |> Enum.any?(fn {existing_params, values} ->
      String.upcase(existing_params) == String.upcase(name_and_params) and
        value in (values |> String.split(",") |> Enum.map(&String.trim/1))
    end)
  end

  defp insert_after_anchor(items, line) do
    case Enum.find_value(@exdate_anchors, &Document.last_index(items, &1)) do
      nil -> items ++ [line]
      index -> List.insert_at(items, index + 1, line)
    end
  end
end
