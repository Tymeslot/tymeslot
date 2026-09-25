defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series do
  @moduledoc """
  Component-level editing of a recurring event stored as one CalDAV resource.

  On CalDAV a series is a single document: the master `VEVENT`, which carries
  the `RRULE`, plus one override `VEVENT` per occurrence edited on its own,
  each naming the slot it replaces with a `RECURRENCE-ID` (RFC 5545 §3.8.4.4).
  Changing one occurrence of the series therefore means rewriting that
  document.

  `ICalBuilder.Patcher` edits properties inside the master and never touches
  an override. This module works one level up: it adds and removes whole
  `VEVENT`s and the properties that tie them to the master's recurrence set
  (`EXDATE`), and leaves every other line of the document, the `VTIMEZONE`
  and each `VALARM` included, exactly as the server returned it.

  ## Occurrence keys

  An occurrence is named the way the cache keys it: its original start as a
  wall-clock stamp in the series' own zone, `YYYYMMDDTHHMMSS` for a timed
  series and `YYYYMMDD` for an all-day one (see `ICalNormaliser`). A
  `RECURRENCE-ID` is reduced to that key by `ICalNormaliser.occurrence_key/2`,
  the same rule the sync applies, so an override is recognised here exactly
  when the sync files it over the same occurrence.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
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

  @doc """
  Removes one occurrence from the series in `document`, identified by `key`:
  the occurrence's original start as the wall-clock stamp the cache keys it
  by (`YYYYMMDDTHHMMSS`, or `YYYYMMDD` all-day) in the series' own zone.

  Adds an `EXDATE` for it to the master, in the value type and zone of the
  master's `DTSTART` (RFC 5545 §3.8.5.1), unless one is already there, and
  drops any override `VEVENT` whose `RECURRENCE-ID` names the same slot.
  `timezone` is the series' IANA zone (`nil` for UTC, floating or all-day),
  used only to read a UTC `RECURRENCE-ID`.

  Returns `{:ok, document}`, or `:empty` when nothing of the series would be
  left (a resource holding only that override), which the caller answers by
  deleting the resource.
  """
  @spec exclude_occurrence(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | :empty
  def exclude_occurrence(document, key, timezone)
      when is_binary(document) and is_binary(key) do
    document
    |> components()
    |> Enum.reject(&override_for?(&1, key, timezone))
    |> Enum.map(&exclude_from_master(&1, key))
    |> serialise()
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
        else: {:vevent, insert_after_anchor(items, exdate_line(exdate))}
    else
      _override_or_no_start -> vevent
    end
  end

  defp exclude_from_master(line, _key), do: line

  # RFC 5545 §3.8.5.1: an EXDATE matches an occurrence only in the value type
  # and zone of DTSTART, so it copies DTSTART's parameters as written, and its
  # UTC marker, around the key.
  defp exdate_for(dtstart, key) do
    {name_and_params, value} = ContentLines.split_value(dtstart)
    params = name_and_params |> String.split(";", parts: 2) |> tl() |> Enum.map_join(&(";" <> &1))
    utc = if String.ends_with?(String.trim(value), ["Z", "z"]), do: "Z", else: ""

    {"EXDATE" <> params, key <> utc}
  end

  defp exdate_line({name_and_params, value}), do: name_and_params <> ":" <> value

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
