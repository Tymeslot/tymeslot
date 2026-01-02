defmodule Tymeslot.Integrations.Calendar.Selection do
  @moduledoc """
  Business logic for calendar discovery/selection merging and preparing params
  for persistence.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary

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
      |> Enum.filter(fn cal -> fetch(cal, "path") in selected_paths end)
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
        {:ok, unify_discovered_with_existing(calendars, integration.calendar_list || [])}

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
      selected = Map.get(existing_map, path, Map.get(existing_map, id, false))

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

  defp maybe_put(acc, nil, _), do: acc
  defp maybe_put(acc, key, val), do: Map.put(acc, key, val)

  @doc """
  Update calendar selection for an integration; sets primary if explicit default provided.
  """
  @spec update_calendar_selection(map(), map()) :: {:ok, any()} | {:error, any()}
  def update_calendar_selection(integration, params) do
    selected_calendar_ids = params["selected_calendars"] || []
    default_calendar_id = params["default_booking_calendar"]

    calendar_list =
      Enum.map(integration.calendar_list || [], fn cal ->
        cal_id = cal["id"] || cal[:id]
        is_selected = cal_id in selected_calendar_ids
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

    result =
      apply_selection_update(
        integration,
        calendar_list,
        selected_calendar_ids,
        default_calendar_id
      )

    result
  end

  defp apply_selection_update(
         integration,
         calendar_list,
         selected_calendar_ids,
         default_calendar_id
       ) do
    cond do
      present_default?(default_calendar_id) and default_calendar_id in selected_calendar_ids ->
        _ = CalendarPrimary.set_primary_calendar_integration(integration.user_id, integration.id)

        attrs = %{
          calendar_list: calendar_list,
          default_booking_calendar_id: default_calendar_id,
          is_active: true
        }

        CalendarManagement.update_calendar_integration(integration, attrs)

      present_default?(default_calendar_id) ->
        {:error, :invalid_default_calendar}

      true ->
        # No explicit default provided; just update the calendar_list selection.
        # For non-primary integrations, do NOT set default_booking_calendar_id.
        attrs = %{calendar_list: calendar_list}
        CalendarManagement.update_calendar_integration(integration, attrs)
    end
  end

  defp present_default?(id), do: is_binary(id) and id != ""
end
