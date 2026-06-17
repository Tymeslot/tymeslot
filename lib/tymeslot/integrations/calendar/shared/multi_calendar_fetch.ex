defmodule Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch do
  @moduledoc """
  Shared logic for fetching events across multiple selected calendars.

  Centralizes the parallel fetching pattern used by multiple providers,
  ensuring consistent behavior and reducing duplication.

  Calendars that return `:not_found` (deleted on the provider side) are
  de-selected as a best-effort side effect so they are not fetched — and
  404 — again on every subsequent availability check.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

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
        results =
          Tymeslot.TaskSupervisor
          |> Task.Supervisor.async_stream(
            selected,
            fn calendar ->
              calendar_id = calendar[:id] || calendar["id"]
              api_module.list_events(integration, calendar_id, start_time, end_time)
            end,
            max_concurrency: @max_concurrency,
            timeout: 30_000
          )
          |> Enum.zip(selected)

        deselect_missing_calendars(integration, results)
        collect_events(results)
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

  def get_selected_calendars(_integration), do: []

  defp collect_events(results) do
    {successes, failures} =
      Enum.split_with(results, fn
        {{:ok, {:ok, _events}}, _calendar} -> true
        _other -> false
      end)

    if successes == [] and failures != [] do
      {:error, :all_calendars_unavailable}
    else
      events =
        successes
        |> Enum.flat_map(fn {{:ok, {:ok, evs}}, _calendar} -> evs end)
        |> Enum.uniq_by(fn event -> event[:id] || event["id"] end)

      {:ok, events}
    end
  end

  defp deselect_missing_calendars(integration, results) do
    missing_ids =
      for {{:ok, {:error, :not_found, _message}}, calendar} <- results do
        calendar[:id] || calendar["id"]
      end

    do_deselect(integration, missing_ids)
  end

  defp do_deselect(_integration, []), do: :ok

  defp do_deselect(%CalendarIntegrationSchema{} = integration, missing_ids) do
    Logger.warning("Selected calendars no longer exist on provider; de-selecting",
      calendar_integration_id: integration.id,
      missing_count: length(missing_ids)
    )

    case CalendarIntegrationQueries.deselect_calendars(integration, missing_ids) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to de-select missing calendars",
          calendar_integration_id: integration.id,
          error: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp do_deselect(_integration, _missing_ids), do: :ok
end
