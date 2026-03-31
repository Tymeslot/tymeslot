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

  alias Tymeslot.DatabaseQueries.CalendarEventCacheQueries
  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast

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
      {:ok, {:ok, event}} ->
        handle_event_fetched(integration, graph_resource_id, event)

      {:ok, :not_found} ->
        handle_event_deleted(integration, graph_resource_id)

      {:error, :unauthorized, _message} ->
        Logger.warning("Outlook Calendar sync unauthorised; discarding job",
          calendar_integration_id: integration.id,
          graph_resource_id: graph_resource_id
        )

        :ok

      {:ok, {:error, reason}} ->
        Logger.error("Outlook Calendar event fetch failed",
          calendar_integration_id: integration.id,
          graph_resource_id: graph_resource_id,
          error: inspect(reason)
        )

        {:error, reason}

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
    params = %{"$select" => @select_fields}
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

    CalendarEventCacheQueries.delete_by_provider_event_id(integration.id, graph_resource_id)
    Sync.reconcile(integration.id, graph_resource_id, nil, :deleted)
    update_last_sync_at(integration)
    :ok
  end

  defp handle_event_fetched(integration, graph_resource_id, event) do
    attrs = OutlookCalendarAPI.to_cache_attrs(event, integration.id)

    case CalendarEventCacheQueries.upsert_batch([attrs]) do
      {:ok, _count} ->
        SyncBroadcast.broadcast_cache_update(integration.user_id, [attrs.uid])
        maybe_reconcile_time_change(integration, graph_resource_id, event)
        update_last_sync_at(integration)
        :ok

      {:error, reason} ->
        Logger.error("Failed to upsert Outlook event into cache",
          calendar_integration_id: integration.id,
          graph_resource_id: graph_resource_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp maybe_reconcile_time_change(integration, graph_resource_id, event) do
    case MeetingQueries.get_by_provider_event_id(integration.id, graph_resource_id) do
      {:ok, meeting} ->
        event_start = parse_outlook_datetime(event["start"])

        if time_changed?(meeting.start_time, event_start) do
          Sync.reconcile(integration.id, graph_resource_id, event["iCalUId"], :modified)
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp time_changed?(_meeting_time, nil), do: false

  defp time_changed?(meeting_time, event_start) do
    DateTime.compare(
      DateTime.truncate(meeting_time, :second),
      DateTime.truncate(event_start, :second)
    ) != :eq
  end

  defp parse_outlook_datetime(nil), do: nil

  defp parse_outlook_datetime(%{"dateTime" => dt_string, "timeZone" => _timezone}) do
    normalized = String.replace(dt_string, ~r/\.\d+$/, "") <> "Z"

    case DateTime.from_iso8601(normalized) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _error -> nil
    end
  end

  defp parse_outlook_datetime(_unknown), do: nil

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
      URI.merge(@base_url, path)
      |> URI.to_string()
      |> then(fn base ->
        if map_size(params) > 0 do
          base <> "?" <> URI.encode_query(params)
        else
          base
        end
      end)

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
