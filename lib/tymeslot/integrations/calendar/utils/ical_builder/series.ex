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
  returned it.

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
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Timing
  alias Tymeslot.Integrations.Calendar.ICalNormaliser

  # A document is read as a list of top-level lines and `{:vevent, items}`
  # components; the items of a VEVENT are its property lines and
  # `{:component, lines}` for each subcomponent (its VALARMs), kept in place so
  # an edit never reorders what it does not touch.
  @typep item :: String.t() | {:component, [String.t()]}
  @typep component :: String.t() | {:vevent, [item()]}

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
    components = components(document)
    zone = series_zone(components, timezone)

    components
    |> Enum.reject(&override_for?(&1, key, zone))
    |> Enum.map(&exclude_from_master(&1, key))
    |> serialise()
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
  new override needs both `:start_time` and `:end_time`, since the master's
  own timing is the first occurrence's, not this one's; without them it is
  `{:error, :missing_timing}`.

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
    components = components(document)
    zone = series_zone(components, timezone)
    index = Enum.find_index(components, &override_for?(&1, key, zone))

    with {:ok, reference} <- reference_start(components, index),
         {:ok, components} <-
           write_override(components, index, reference, key, changes, timezone, mode) do
      serialise(components)
    end
  end

  # The series' zone is its master's DTSTART's (`Timing.zone/2`), not the
  # zone of whichever cached row asked: an override's row carries the zone of
  # its own DTSTART, which another client may have written in UTC or another
  # zone. `timezone` stands in only where the document cannot say.
  defp series_zone(components, timezone) do
    case Enum.find(components, &master?/1) do
      {:vevent, items} -> Timing.zone(ContentLines.find("DTSTART", properties(items)), timezone)
      nil -> timezone
    end
  end

  # --- Writing an override ---

  # The form every timing line of the override takes: the master's DTSTART,
  # or, in a resource holding only overrides, the override's own.
  defp reference_start(components, index) do
    reference =
      case Enum.find(components, &master?/1) do
        {:vevent, items} -> ContentLines.find("DTSTART", properties(items))
        nil when is_integer(index) -> own_start(Enum.at(components, index))
        nil -> nil
      end

    if reference, do: {:ok, reference}, else: {:error, :occurrence_not_found}
  end

  defp own_start({:vevent, items}), do: ContentLines.find("DTSTART", properties(items))

  defp master?({:vevent, items}) do
    properties = properties(items)

    is_nil(ContentLines.find("RECURRENCE-ID", properties)) and
      is_binary(ContentLines.find("DTSTART", properties))
  end

  defp master?(_line), do: false

  defp write_override(components, nil, reference, key, changes, timezone, mode) do
    with :ok <- ensure_timing(changes),
         {:vevent, items} <- Enum.find(components, &master?/1),
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

  # Timing arrives as a `Date` or a `DateTime`; anything else is no timing.
  defp ensure_timing(%{start_time: start, end_time: finish})
       when is_struct(start) and is_struct(finish),
       do: :ok

  defp ensure_timing(_changes), do: {:error, :missing_timing}

  # The master's own lines stand in for the occurrence's until `changes` say
  # otherwise, named by the slot it replaces; a fresh DTSTAMP comes with the
  # patch.
  defp from_master(items, reference, key) do
    items
    |> Enum.reject(&(is_binary(&1) and ContentLines.property_name(&1) in @recurrence_properties))
    |> insert_after("DTSTART", property_line(slot_for("RECURRENCE-ID", reference, key)))
  end

  defp edit_items(items, reference, changes, timezone, mode) do
    patched =
      items
      |> Enum.flat_map(&item_lines/1)
      |> Patcher.patch_vevent(Map.drop(changes, @series_keys), mode)
      |> collect_items()

    with :ok <- ensure_value_type(reference, changes) do
      put_timing(patched, reference, changes, timezone)
    end
  end

  defp ensure_value_type(reference, %{start_time: start}) when is_struct(start) do
    if match?(%Date{}, start) == Timing.date?(reference),
      do: :ok,
      else: {:error, :value_type_change}
  end

  defp ensure_value_type(_reference, _changes), do: :ok

  defp put_timing(items, reference, changes, timezone) do
    with {:ok, items} <- put_start(items, reference, changes, timezone) do
      put_end(items, reference, changes, timezone)
    end
  end

  defp put_start(items, reference, %{start_time: start}, timezone) when is_struct(start) do
    with {:ok, line} <- Timing.line("DTSTART", start, reference, timezone) do
      {:ok, replace_properties(items, ["DTSTART"], line)}
    end
  end

  defp put_start(items, _reference, _changes, _timezone), do: {:ok, items}

  defp put_end(items, reference, %{end_time: finish} = changes, timezone)
       when is_struct(finish) do
    finish = end_boundary(finish, Map.get(changes, :start_time))

    with {:ok, line} <- Timing.line("DTEND", finish, reference, timezone) do
      {:ok, replace_properties(items, ["DTEND", "DURATION"], line)}
    end
  end

  defp put_end(items, _reference, _changes, _timezone), do: {:ok, items}

  defp end_boundary(%Date{} = finish, %Date{} = start), do: Timing.exclusive_end(finish, start)
  defp end_boundary(finish, _start), do: finish

  # The new line takes the place of the first property it replaces, so the
  # override reads in the order the server wrote it; one with none of them
  # gains it after its DTSTART.
  defp replace_properties(items, names, line) do
    replaced? = &(is_binary(&1) and ContentLines.property_name(&1) in names)

    case Enum.find_index(items, replaced?) do
      nil ->
        insert_after(items, "DTSTART", line)

      index ->
        items
        |> List.replace_at(index, line)
        |> Enum.with_index()
        |> Enum.reject(fn {item, at} -> at != index and replaced?.(item) end)
        |> Enum.map(&elem(&1, 0))
    end
  end

  defp insert_after(items, name, line) do
    case last_index(items, name) do
      nil -> [line | items]
      index -> List.insert_at(items, index + 1, line)
    end
  end

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

  defp override_for?({:vevent, items}, key, timezone) do
    case ContentLines.find("RECURRENCE-ID", properties(items)) do
      nil ->
        false

      line ->
        {_name, value} = ContentLines.split_value(line)
        ICalNormaliser.occurrence_key(value, timezone) == key
    end
  end

  defp override_for?(_line, _key, _timezone), do: false

  defp exclude_from_master({:vevent, items} = vevent, key) do
    properties = properties(items)

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
    case Enum.find_value(@exdate_anchors, &last_index(items, &1)) do
      nil -> items ++ [line]
      index -> List.insert_at(items, index + 1, line)
    end
  end

  defp last_index(items, name) do
    items
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {line, index} when is_binary(line) -> if ContentLines.property_name(line) == name, do: index
      _subcomponent -> nil
    end)
  end

  # --- Reading and writing the document ---

  @spec components(String.t()) :: [component()]
  defp components(document), do: document |> ContentLines.split() |> collect_components()

  defp collect_components([]), do: []

  defp collect_components(["BEGIN:VEVENT" | rest]) do
    {body, remaining} = ContentLines.take_until(rest, "END:VEVENT")
    [{:vevent, collect_items(body)} | collect_components(remaining)]
  end

  defp collect_components([line | rest]), do: [line | collect_components(rest)]

  @spec collect_items([String.t()]) :: [item()]
  defp collect_items([]), do: []

  defp collect_items(["BEGIN:" <> name = line | rest]) do
    {body, remaining} = ContentLines.take_until(rest, "END:" <> name)
    [{:component, [line | body] ++ ["END:" <> name]} | collect_items(remaining)]
  end

  defp collect_items([line | rest]), do: [line | collect_items(rest)]

  defp properties(items), do: Enum.filter(items, &is_binary/1)

  # A document left without any VEVENT holds nothing of the series; the
  # caller deletes the resource rather than storing an empty calendar.
  defp serialise(components) do
    if Enum.any?(components, &match?({:vevent, _items}, &1)),
      do: {:ok, components |> Enum.flat_map(&component_lines/1) |> ContentLines.join()},
      else: :empty
  end

  defp component_lines({:vevent, items}),
    do: ["BEGIN:VEVENT"] ++ Enum.flat_map(items, &item_lines/1) ++ ["END:VEVENT"]

  defp component_lines(line), do: [line]

  defp item_lines({:component, lines}), do: lines
  defp item_lines(line), do: [line]
end
