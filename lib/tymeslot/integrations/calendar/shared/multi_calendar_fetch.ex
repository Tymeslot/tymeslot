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

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate.Outcome

  @max_concurrency 20

  @doc """
  Lists events using selected calendars when available; otherwise falls back to
  the provider's primary events endpoint.

  Expects an API module implementing:
  - list_primary_events(integration, start_time, end_time)
  - list_events(integration, calendar_id, start_time, end_time)

  Returns `{:error, %FetchAggregate.Outcome{}}` when at least one selected
  calendar fails — whether every one of them failed or only some did — so
  the caller can see exactly which calendars failed and why, rather than a
  single opaque atom. A partial result is never reported as `{:ok, _}`: a
  calendar we failed to read from is a calendar whose busy time we don't
  know, not a calendar with no events. This function does not itself decide
  fail-open vs. fail-closed policy — see `FetchAggregate.require_complete/1`,
  applied once at the outermost availability boundary.
  """
  @spec list_events_with_selection(map(), DateTime.t(), DateTime.t(), module()) ::
          {:ok, list()} | {:error, Outcome.t()} | {:error, term()}
  def list_events_with_selection(integration, start_time, end_time, api_module) do
    case get_selected_calendars(integration) do
      [] ->
        api_module.list_primary_events(integration, start_time, end_time)

      selected ->
        results =
          Tymeslot.TaskSupervisor
          |> Task.Supervisor.async_stream_nolink(
            selected,
            fn calendar ->
              api_module.list_events(integration, calendar.id, start_time, end_time)
            end,
            max_concurrency: @max_concurrency,
            timeout: 30_000,
            on_timeout: :kill_task
          )
          |> Enum.zip(selected)

        deselect_missing_calendars(integration, results)
        collect_events(results)
    end
  end

  @doc """
  Returns the selected calendars (read-only included, per
  `Selection.selected_calendars/1` — this only reads events, it never
  writes) that also have an id present.
  """
  @spec get_selected_calendars(map()) :: [CalendarEntry.t()]
  def get_selected_calendars(%{calendar_list: calendar_list}) when is_list(calendar_list) do
    calendar_list
    |> Enum.map(&CalendarEntry.normalize/1)
    |> Selection.selected_calendars()
    |> Enum.filter(& &1.id)
  end

  def get_selected_calendars(_integration), do: []

  # Events are a separate shape from calendar entries: Outlook's API module
  # normalises to atom keys, Google's returns the raw string-keyed payload.
  # Dispatch on shape once here instead of probing both key types at every
  # read.
  defp event_id(%{id: id}), do: id
  defp event_id(%{"id" => id}), do: id
  defp event_id(_event), do: nil

  # Classifies each `{task_result, calendar}` pair for `FetchAggregate.collect/3`
  # into a real success, a confirmed-absent calendar (404 → already
  # de-selected above, so an empty contribution is correct, not a gap), or a
  # hard failure whose busy time we simply don't know (timeout, auth error,
  # network error, killed task). This module does not apply fail-closed
  # policy itself (see `collect_events/1` below); that is reserved for the
  # outermost availability boundary, `EventQueries.resolve_availability_fetch/3`.
  defp classify_calendar_result({{:ok, {:ok, events}}, _calendar}), do: {:ok, events}
  defp classify_calendar_result({{:ok, {:error, :not_found, _message}}, _calendar}), do: :absent

  defp classify_calendar_result({{:ok, {:error, reason, _message}}, calendar}),
    do: {:error, calendar.id, reason}

  defp classify_calendar_result({{:ok, {:error, reason}}, calendar}),
    do: {:error, calendar.id, reason}

  defp classify_calendar_result({{:exit, reason}, calendar}), do: {:error, calendar.id, reason}

  # Defensive catch-all: a future provider result shape should degrade to a
  # hard failure, not crash the whole fetch.
  defp classify_calendar_result({_other, calendar}), do: {:error, calendar.id, :unexpected_result}

  # Deliberately does not call `FetchAggregate.require_complete/1`: that
  # applies fail-closed *policy* (what a partial fetch means to the caller),
  # and is reserved for the single outermost call site that makes an
  # availability decision. Here we only report the raw `Outcome` on any hard
  # failure so it can be merged into the outer level's own `Outcome` — via
  # `FetchAggregate.collect/3`'s `{:aggregate, outcome}` classification —
  # instead of being flattened into an opaque atom that discards which
  # calendar failed and why.
  defp collect_events(results) do
    results
    |> FetchAggregate.collect(&classify_calendar_result/1)
    |> dedupe_outcome_events()
    |> to_result()
  end

  defp dedupe_outcome_events(%Outcome{events: events} = outcome) do
    %{outcome | events: Enum.uniq_by(events, &event_id/1)}
  end

  defp to_result(%Outcome{failed: []} = outcome), do: {:ok, outcome.events}
  defp to_result(%Outcome{} = outcome), do: {:error, outcome}

  defp deselect_missing_calendars(integration, results) do
    missing_ids =
      for {{:ok, {:error, :not_found, _message}}, calendar} <- results do
        calendar.id
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
