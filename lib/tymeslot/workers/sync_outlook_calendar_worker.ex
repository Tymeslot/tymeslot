defmodule Tymeslot.Workers.SyncOutlookCalendarWorker do
  @moduledoc """
  Oban worker that syncs a single Outlook Calendar event after receiving a
  Microsoft Graph change notification.

  Each job targets one event identified by `graph_resource_id`. The worker
  fetches the event from Graph, upserts it into the local cache, and
  reconciles any linked Tymeslot meeting whose times may have changed.

  On a 404 (event deleted by the user) the cache row is removed and the linked
  meeting (if any) is reconciled with `:deleted`. On 401 the job is silently
  discarded rather than retried, matching REQ-012.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 5,
    unique: [period: 60, keys: [:calendar_integration_id, :graph_resource_id]]

  require Logger

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck

  # CalendarGrid enqueues Outlook jobs with only calendar_integration_id (no graph_resource_id).
  # Outlook syncs are event-driven via Microsoft Graph webhooks — there is no full-sync path yet.
  # Discard these jobs gracefully rather than crashing.
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id} = args})
      when not is_map_key(args, "graph_resource_id") do
    Logger.warning(
      "SyncOutlookCalendarWorker requires graph_resource_id; discarding calendar-grid-triggered job",
      calendar_integration_id: integration_id
    )

    {:discard, "graph_resource_id required — Outlook syncs are webhook-driven"}
  end

  def perform(%Oban.Job{
        args: %{
          "calendar_integration_id" => integration_id,
          "graph_resource_id" => graph_resource_id
        }
      }) do
    Logger.metadata(
      calendar_integration_id: integration_id,
      graph_resource_id: graph_resource_id
    )

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        sync_event(integration, graph_resource_id)

      {:error, :not_found} ->
        Logger.warning("Calendar integration not found, discarding sync job",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp sync_event(integration, graph_resource_id) do
    result =
      AccessToken.with_access_token(integration, &OutlookCalendarAPI.refresh_token/1, fn token ->
        # Check for 404 (deleted event) and 401 BEFORE the circuit breaker so
        # that deleted events and auth failures don't count as failures and
        # trip the breaker.
        case OutlookCalendarAPI.get_event_raw(token, graph_resource_id) do
          {:error, :not_found, _message} ->
            {:ok, :not_found}

          {:error, :unauthorized, message} ->
            {:error, :unauthorized, message}

          preflight_result ->
            CalendarCircuitBreaker.call(:outlook, fn ->
              # The circuit breaker only counts 2-tuple errors as failures,
              # so flatten the client's {:error, type, message} shape.
              case preflight_result do
                {:ok, event} -> {:ok, event}
                {:error, type, message} -> {:error, {type, message}}
              end
            end)
        end
      end)

    handle_sync_result(result, integration, graph_resource_id)
  end

  defp handle_sync_result(result, integration, graph_resource_id) do
    case result do
      {:ok, :not_found} ->
        handle_event_deleted(integration, graph_resource_id)

      {:ok, event} when is_map(event) ->
        handle_event_fetched(integration, graph_resource_id, event)

      {:error, :unauthorized, _message} ->
        Logger.warning("Outlook Calendar sync unauthorised; discarding job",
          calendar_integration_id: integration.id,
          graph_resource_id: graph_resource_id
        )

        :ok

      {:error, :circuit_open} ->
        Logger.warning("Outlook Calendar circuit breaker open; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, 120}

      {:error, {:rate_limited, message}} ->
        Logger.warning("Outlook Calendar sync rate limited; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, retry_after_seconds(message)}

      {:error, reason} ->
        Logger.error("Outlook Calendar sync failed",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  # The canonical client encodes a server-provided Retry-After as
  # "retry_after:N" in the rate-limit error message.
  defp retry_after_seconds("retry_after:" <> seconds) do
    case Integer.parse(seconds) do
      {n, _rest} when n > 0 -> min(n, 600)
      _no_parse -> 120
    end
  end

  defp retry_after_seconds(_message), do: 120

  defp handle_event_deleted(integration, graph_resource_id) do
    Logger.info("Outlook Calendar event deleted; removing from cache",
      calendar_integration_id: integration.id,
      graph_resource_id: graph_resource_id
    )

    Sync.reconcile_deletions(integration, [%{provider_event_id: graph_resource_id, uid: nil}])
    update_last_sync_at(integration)
    :ok
  end

  defp handle_event_fetched(integration, graph_resource_id, event) do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: integration.default_booking_calendar_id || "primary",
      synced_at: DateTime.utc_now(:microsecond)
    }

    case OutlookProvider.normalise_events([event], context) do
      {:ok, [_cal_event | _rest] = calendar_events} ->
        Sync.persist_normalised_events(integration, calendar_events)
        update_last_sync_at(integration)
        :ok

      {:ok, []} ->
        Logger.warning("Outlook event could not be normalised; skipping",
          calendar_integration_id: integration.id,
          graph_resource_id: graph_resource_id
        )

        update_last_sync_at(integration)
        :ok
    end
  end

  defp update_last_sync_at(integration) do
    result =
      CalendarIntegrationQueries.update_sync_state(integration, %{
        last_external_sync_at: DateTime.utc_now(:second)
      })

    HealthCheck.mark_synced_successfully(:calendar, integration.id)

    case result do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist Outlook Calendar sync state",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        :ok
    end
  end
end
