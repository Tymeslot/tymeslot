defmodule Tymeslot.Integrations.Calendar.Selection do
  @moduledoc """
  Business logic for calendar discovery/selection merging and preparing params
  for persistence.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Utils.UriUtils

  @doc """
  Build the params fragment based on selected calendar paths and discovered items.

  - selected_paths: list of strings
  - discovered: list of calendars with at least path/name/type keys (string or atom keys)

  Returns a map suitable for merging into creation/update params:
    %{calendar_paths: ["a", "b", "c"], calendar_list: [%{"id" => ..., ...}]}
  """
  @spec prepare_selected_params([String.t()], list()) :: map()
  def prepare_selected_params(selected_paths, discovered) when is_list(selected_paths) do
    calendar_paths = selected_paths

    selected_calendar_info =
      discovered
      |> Enum.filter(fn cal -> path_in_selected?(fetch(cal, "path"), selected_paths) end)
      |> Enum.map(fn cal ->
        %{
          "id" => fetch(cal, "id") || fetch(cal, :id) || fetch(cal, "path"),
          "path" => fetch(cal, "path"),
          "name" => fetch(cal, "name") || "Calendar",
          "type" => fetch(cal, "type") || "calendar",
          "selected" => true
        }
      end)

    %{"calendar_paths" => calendar_paths, "calendar_list" => selected_calendar_info}
  end

  @doc """
  Discover calendars for the given integration and merge with existing selection
  state (integration.calendar_list), returning a unified list where each item
  includes a boolean "selected" field.
  """
  @spec discover_with_selection(map()) :: {:ok, list()} | {:error, term()}
  def discover_with_selection(integration) do
    case Calendar.discover_calendars_for_integration(integration) do
      {:ok, calendars} ->
        {:ok, unify_discovered_with_existing(calendars, integration.calendar_list)}

      error ->
        error
    end
  end

  @doc """
  Merge discovered calendars with an existing list of selections.
  """
  @spec unify_discovered_with_existing(list(), list()) :: list()
  def unify_discovered_with_existing(discovered, existing_list) do
    existing_map = build_existing_selection_map(existing_list)

    Enum.map(discovered, fn cal ->
      path = fetch(cal, "path")
      id = fetch(cal, "id") || path
      selected = lookup_selection(existing_map, [path, id])

      %{
        "id" => id,
        "path" => path,
        "name" => fetch(cal, "name") || "Calendar",
        "type" => fetch(cal, "type") || "calendar",
        "selected" => selected
      }
    end)
  end

  defp build_existing_selection_map(existing) do
    Enum.reduce(existing, %{}, fn cal, acc ->
      selected = fetch(cal, "selected") || false
      path = fetch(cal, "path")
      id = fetch(cal, "id")

      acc
      |> maybe_put(path, selected)
      |> maybe_put(id, selected)
      |> maybe_put_decoded(path, selected)
      |> maybe_put_decoded(id, selected)
    end)
  end

  defp fetch(map, key) when is_binary(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      key == "id" -> Map.get(map, :id)
      key == "path" -> Map.get(map, :path)
      key == "name" -> Map.get(map, :name)
      key == "type" -> Map.get(map, :type)
      key == "selected" -> Map.get(map, :selected)
      true -> nil
    end
  end

  defp fetch(map, key) when is_atom(key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, Atom.to_string(key))
    end
  end

  defp path_in_selected?(path, selected_paths) do
    Enum.any?(selected_paths, &UriUtils.uri_safe_match?(path, &1))
  end

  # Looks up a selection boolean for a calendar identified by any of the given
  # keys (tried in order). Treats false and true as distinct — unlike `||`, this
  # returns false immediately when a key is present with that value rather than
  # continuing to the next candidate.
  defp lookup_selection(existing_map, keys) do
    keys
    |> Enum.flat_map(fn
      nil -> []
      key -> [key, UriUtils.safe_decode(key)]
    end)
    |> Enum.find_value(false, fn key ->
      if Map.has_key?(existing_map, key), do: Map.fetch!(existing_map, key)
    end)
  end

  defp maybe_put(acc, nil, _val), do: acc
  defp maybe_put(acc, key, val), do: Map.put(acc, key, val)

  defp maybe_put_decoded(acc, nil, _val), do: acc

  defp maybe_put_decoded(acc, key, val) do
    decoded = UriUtils.safe_decode(key)
    if decoded == key, do: acc, else: Map.put(acc, decoded, val)
  end

  @doc """
  Update calendar selection for an integration.
  """
  @spec update_calendar_selection(map(), map()) :: {:ok, any()} | {:error, any()}
  def update_calendar_selection(integration, params) do
    selected_calendar_ids = params["selected_calendars"] || []

    calendar_list =
      Enum.map(integration.calendar_list || [], fn cal ->
        cal_id = cal["id"] || cal[:id]
        is_selected = Enum.any?(selected_calendar_ids, &UriUtils.uri_safe_match?(cal_id, &1))
        base_map = Enum.into(cal, %{})

        Map.merge(
          %{
            "id" => cal_id,
            "selected" => is_selected,
            "name" => base_map["name"] || base_map[:name],
            "type" => base_map["type"] || base_map[:type] || "calendar",
            "path" => base_map["path"] || base_map[:path] || cal_id
          },
          Map.drop(base_map, ["selected", :selected])
        )
      end)

    CalendarManagement.update_calendar_integration(integration, %{calendar_list: calendar_list})
  end
end
