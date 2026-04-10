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
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Sync

  @base_url "https://graph.microsoft.com/v1.0"

  @select_fields "id,subject,start,end,iCalUId,location,bodyPreview,attendees,recurrence,seriesMasterId,type,isAllDay,showAs"

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
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp sync_event(integration, graph_resource_id) do
    result =
      AccessToken.with_access_token(integration, &OutlookCalendarAPI.refresh_token/1, fn token ->
        # Check for 404 (deleted event) BEFORE the circuit breaker so that
        # deleted events don't count as failures and trip the breaker.
        case fetch_event_raw(token, graph_resource_id) do
          {:ok, :not_found} ->
            {:ok, :not_found}

          {:ok, :unauthorized} ->
            {:error, :unauthorized, "Token expired or invalid"}

          preflight_result ->
            CalendarCircuitBreaker.call(:outlook, fn ->
              case preflight_result do
                {:ok, event} -> {:ok, event}
                {:error, reason} -> {:error, reason}
              end
            end)
        end
      end)

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

      {:error, reason} ->
        Logger.error("Outlook Calendar sync failed",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp fetch_event_raw(token, graph_resource_id) do
    path = "/me/events/#{graph_resource_id}"

    params = %{
      "$select" => @select_fields,
      "$expand" =>
        "singleValueExtendedProperties($filter=id eq '#{OutlookCalendarAPI.tymeslot_property_id()}')"
    }

    headers = [{"Prefer", "outlook.timezone=\"UTC\""}]

    case http_get(token, path, params, headers) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        case Jason.decode(body) do
          {:ok, event} -> {:ok, event}
          {:error, _reason} -> {:error, :invalid_json}
        end

      {:ok, %{status: 401}} ->
        {:ok, :unauthorized}

      {:ok, %{status: 404}} ->
        {:ok, :not_found}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Outlook Graph API unexpected status",
          status: status,
          body: String.slice(body, 0, 500)
        )

        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp handle_event_deleted(integration, graph_resource_id) do
    Logger.info("Outlook Calendar event deleted; removing from cache",
      calendar_integration_id: integration.id,
      graph_resource_id: graph_resource_id
    )

    ProviderCalendarEventQueries.delete_by_provider_event_id(integration.id, graph_resource_id)
    Sync.reconcile(integration.id, graph_resource_id, nil, :deleted)
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
    case CalendarIntegrationQueries.update_sync_state(integration, %{
           last_external_sync_at: DateTime.utc_now(:second)
         }) do
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

  defp http_get(token, path, params, extra_headers) do
    url =
      if map_size(params) > 0 do
        @base_url <> path <> "?" <> URI.encode_query(params)
      else
        @base_url <> path
      end

    headers =
      [
        {"Authorization", "Bearer #{token}"},
        {"Content-Type", "application/json"}
      ] ++ extra_headers

    http_client().request(:get, url, "", headers, [])
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, HTTPClient)
  end
end
