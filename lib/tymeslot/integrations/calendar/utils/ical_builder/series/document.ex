defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series.Document do
  @moduledoc """
  A recurring event's CalDAV resource read as components, for the modules
  that edit one (`ICalBuilder.Series`, `ICalBuilder.Series.Master`).

  A document is a list of top-level lines and `{:vevent, items}` components;
  the items of a `VEVENT` are its property lines and `{:component, lines}` for
  each subcomponent (its `VALARM`s), kept in place so an edit never reorders
  what it does not touch. Lines are unfolded on the way in and folded again
  on the way out (`ICalBuilder.ContentLines`).
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Timing
  alias Tymeslot.Integrations.Calendar.ICalNormaliser

  @type item :: String.t() | {:component, [String.t()]}
  @type component :: String.t() | {:vevent, [item()]}

  @doc "Reads `document` as components."
  @spec components(String.t()) :: [component()]
  def components(document), do: document |> ContentLines.split() |> collect_components()

  @doc """
  Writes components back as a folded document. A document left without any
  `VEVENT` holds nothing of the series and is `:empty`; the caller deletes
  the resource rather than storing an empty calendar.
  """
  @spec serialise([component()]) :: {:ok, String.t()} | :empty
  def serialise(components) do
    if Enum.any?(components, &match?({:vevent, _items}, &1)),
      do: {:ok, components |> Enum.flat_map(&component_lines/1) |> ContentLines.join()},
      else: :empty
  end

  @doc "Reads unfolded `VEVENT` body lines as items."
  @spec collect_items([String.t()]) :: [item()]
  def collect_items([]), do: []

  def collect_items(["BEGIN:" <> name = line | rest]) do
    {body, remaining} = ContentLines.take_until(rest, "END:" <> name)
    [{:component, [line | body] ++ ["END:" <> name]} | collect_items(remaining)]
  end

  def collect_items([line | rest]), do: [line | collect_items(rest)]

  @doc "The content lines an item stands for."
  @spec item_lines(item()) :: [String.t()]
  def item_lines({:component, lines}), do: lines
  def item_lines(line), do: [line]

  @doc "The property lines among `items`, subcomponents left out."
  @spec properties([item()]) :: [String.t()]
  def properties(items), do: Enum.filter(items, &is_binary/1)

  @doc "Whether `component` is the series' master: a `VEVENT` with a start and no `RECURRENCE-ID`."
  @spec master?(component()) :: boolean()
  def master?({:vevent, items}) do
    properties = properties(items)

    is_nil(ContentLines.find("RECURRENCE-ID", properties)) and
      is_binary(ContentLines.find("DTSTART", properties))
  end

  def master?(_line), do: false

  @doc """
  Whether `component` is the override of the occurrence `key` names, its
  `RECURRENCE-ID` reduced to a key the way the sync reduces it
  (`ICalNormaliser.occurrence_key/2`) in `timezone`, the series' zone.
  """
  @spec override_for?(component(), String.t(), String.t() | nil) :: boolean()
  def override_for?({:vevent, items}, key, timezone) do
    case ContentLines.find("RECURRENCE-ID", properties(items)) do
      nil ->
        false

      line ->
        {_name, value} = ContentLines.split_value(line)
        ICalNormaliser.occurrence_key(value, timezone) == key
    end
  end

  def override_for?(_line, _key, _timezone), do: false

  @doc """
  The series' zone: its master's `DTSTART`'s (`Timing.zone/2`), not the zone
  of whichever cached row asked. An override's row carries the zone of its
  own `DTSTART`, which another client may have written in UTC or another
  zone. `timezone` stands in only where the document cannot say.
  """
  @spec series_zone([component()], String.t() | nil) :: String.t() | nil
  def series_zone(components, timezone) do
    case Enum.find(components, &master?/1) do
      {:vevent, items} -> Timing.zone(ContentLines.find("DTSTART", properties(items)), timezone)
      nil -> timezone
    end
  end

  @doc """
  Puts `line` in the place of the first property named in `names`, dropping
  the rest, so a `VEVENT` reads in the order the server wrote it; one with
  none of them gains it after its `DTSTART`.
  """
  @spec replace_properties([item()], [String.t()], String.t()) :: [item()]
  def replace_properties(items, names, line) do
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

  @doc "Inserts `line` after the last property `name`, or first when there is none."
  @spec insert_after([item()], String.t(), String.t()) :: [item()]
  def insert_after(items, name, line) do
    case last_index(items, name) do
      nil -> [line | items]
      index -> List.insert_at(items, index + 1, line)
    end
  end

  @doc "The index of the last property `name` among `items`, or `nil`."
  @spec last_index([item()], String.t()) :: non_neg_integer() | nil
  def last_index(items, name) do
    items
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {line, index} when is_binary(line) -> if ContentLines.property_name(line) == name, do: index
      _subcomponent -> nil
    end)
  end

  @doc """
  Maps `fun`, which answers `{:ok, value}` or an error, over `list`: the
  mapped list, or the first error.
  """
  @spec map_ok(list(), (term() -> {:ok, term()} | term())) :: {:ok, list()} | term()
  def map_ok(list, fun) do
    result =
      Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
        case fun.(item) do
          {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      error -> error
    end
  end

  defp collect_components([]), do: []

  defp collect_components(["BEGIN:VEVENT" | rest]) do
    {body, remaining} = ContentLines.take_until(rest, "END:VEVENT")
    [{:vevent, collect_items(body)} | collect_components(remaining)]
  end

  defp collect_components([line | rest]), do: [line | collect_components(rest)]

  defp component_lines({:vevent, items}),
    do: ["BEGIN:VEVENT"] ++ Enum.flat_map(items, &item_lines/1) ++ ["END:VEVENT"]

  defp component_lines(line), do: [line]
end
