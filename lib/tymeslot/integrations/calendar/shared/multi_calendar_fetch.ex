defmodule Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch do
  @moduledoc """
  Shared logic for fetching events across multiple selected calendars.

  Centralizes the parallel fetching pattern used by multiple providers,
  ensuring consistent behavior and reducing duplication.
  """

  @max_concurrency 20

  @doc """
  Lists events using selected calendars when available; otherwise falls back to
  the provider's primary events endpoint.

  Expects an API module implementing:
  - list_primary_events(integration, start_time, end_time)
  - list_events(integration, calendar_id, start_time, end_time)
  """
  @spec list_events_with_selection(map(), DateTime.t(), DateTime.t(), module()) ::
          {:ok, list()} | {:error, term()}
  def list_events_with_selection(integration, start_time, end_time, api_module) do
    case get_selected_calendars(integration) do
      [] ->
        api_module.list_primary_events(integration, start_time, end_time)

      selected ->
        events =
          selected
          |> Task.async_stream(
            fn calendar ->
              calendar_id = calendar[:id] || calendar["id"]
              api_module.list_events(integration, calendar_id, start_time, end_time)
            end,
            max_concurrency: @max_concurrency,
            timeout: 30_000
          )
          |> Enum.flat_map(fn
            {:ok, {:ok, evs}} -> evs
            _ -> []
          end)
          |> Enum.uniq_by(& &1["id"])

        {:ok, events}
    end
  end

  @doc """
  Returns only calendars with selected=true and an id present.
  Supports either atom or string keys.
  """
  @spec get_selected_calendars(map()) :: list()
  def get_selected_calendars(%{calendar_list: calendar_list}) when is_list(calendar_list) do
    Enum.filter(calendar_list, fn calendar ->
      (calendar[:selected] || calendar["selected"]) && (calendar[:id] || calendar["id"])
    end)
  end

  def get_selected_calendars(_), do: []
end
