defmodule Tymeslot.Workers.SyncGoogleCalendarWorker do
  @moduledoc """
  Oban worker that performs an incremental sync of a Google Calendar integration
  after receiving a push notification.

  Fetches the delta since the last sync using the stored `google_sync_token`,
  upserts or removes events in the local cache, and reconciles any linked
  Tymeslot meetings whose times have changed or that have been deleted.

  On sync-token expiry (HTTP 410) the worker re-registers the push channel to
  obtain a fresh token; the next webhook or fallback sweep will pick up the full
  delta.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 5,
    unique: [
      period: 300,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleCalendarAPI
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck

  @sync_window_past_days ProviderConfig.sync_window_past_days()
  @sync_window_future_days ProviderConfig.sync_window_future_days()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}}) do
    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        sync_integration(integration)

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

  defp google_calendar_api do
    Application.get_env(:tymeslot, :google_calendar_api_module, GoogleCalendarAPI)
  end

  defp sync_integration(integration) do
    case google_calendar_api().list_events_incremental(integration) do
      {:ok, %{events: events, next_sync_token: next_sync_token}} ->
        Logger.info("Incremental Google Calendar sync fetched events",
          calendar_integration_id: integration.id,
          event_count: length(events)
        )

        process_incremental_sync(integration, events, next_sync_token)

      {:error, :gone, _message} ->
        Logger.warning(
          "Google Calendar sync token expired; performing full bootstrap resync",
          calendar_integration_id: integration.id
        )

        bootstrap_integration(integration)

      {:error, :no_sync_token} ->
        Logger.info(
          "Google Calendar integration has no sync token; performing initial bootstrap",
          calendar_integration_id: integration.id
        )

        bootstrap_integration(integration)

      {:error, :unauthorized, _message} ->
        Logger.warning("Google Calendar sync unauthorised; discarding job",
          calendar_integration_id: integration.id
        )

        :ok

      {:error, :circuit_open} ->
        Logger.warning("Google Calendar circuit breaker open; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, 120}

      {:error, reason} ->
        Logger.error("Google Calendar incremental sync failed",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp bootstrap_integration(integration) do
    case google_calendar_api().bootstrap_sync(integration) do
      {:ok, %{events: events, next_sync_token: next_sync_token}} ->
        Logger.info("Google Calendar bootstrap fetched events",
          calendar_integration_id: integration.id,
          event_count: length(events)
        )

        process_incremental_sync(integration, events, next_sync_token)

      {:error, :unauthorized, _message} ->
        Logger.warning("Google Calendar bootstrap unauthorised; skipping",
          calendar_integration_id: integration.id
        )

        :ok

      {:error, :circuit_open} ->
        Logger.warning("Google Calendar circuit breaker open during bootstrap; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, 120}

      {:error, _type, reason} ->
        Logger.error("Google Calendar bootstrap failed",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp process_incremental_sync(integration, events, next_sync_token) do
    with :ok <- safe_process_events(integration, events),
         :ok <- persist_sync_state(integration, next_sync_token),
         :ok <- sync_secondary_calendars(integration) do
      SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
      :ok
    else
      {:error, reason} ->
        Logger.error("Google Calendar event processing failed; sync token NOT updated",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}

      other ->
        other
    end
  end

  defp sync_secondary_calendars(integration) do
    primary_id = integration.default_booking_calendar_id || "primary"

    secondary_ids =
      integration.calendar_list
      |> Enum.filter(fn cal ->
        (cal["selected"] || cal[:selected]) == true and
          (cal["id"] || cal[:id]) != primary_id
      end)
      |> Enum.map(fn cal -> cal["id"] || cal[:id] end)

    if secondary_ids == [] do
      :ok
    else
      now = DateTime.utc_now()
      start_time = DateTime.add(now, -@sync_window_past_days, :day)
      end_time = DateTime.add(now, @sync_window_future_days, :day)

      Enum.reduce_while(secondary_ids, :ok, fn calendar_id, _acc ->
        case google_calendar_api().list_events(integration, calendar_id, start_time, end_time) do
          {:ok, events} ->
            case safe_process_events(integration, events, calendar_id) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end

          {:error, :circuit_open} ->
            Logger.warning("Google Calendar circuit breaker open during secondary sync; snoozing",
              calendar_integration_id: integration.id
            )

            {:halt, {:snooze, 120}}

          {:error, :unauthorized, _message} ->
            Logger.warning("Google Calendar secondary sync unauthorised; skipping calendar",
              calendar_integration_id: integration.id,
              calendar_id: calendar_id
            )

            {:cont, :ok}

          {:error, reason} ->
            Logger.error("Google Calendar secondary sync failed",
              calendar_integration_id: integration.id,
              calendar_id: calendar_id,
              error: inspect(reason)
            )

            {:halt, {:error, reason}}
        end
      end)
    end
  end

  # Best-effort: normalise all events via the provider, then delegate to
  # the shared persistence pipeline in `Sync`. Cancelled events are handled
  # separately — they are deleted from the cache and reconciled as deletions.
  defp safe_process_events(integration, raw_events, calendar_id \\ nil) do
    {cancelled, active} =
      Enum.split_with(raw_events, fn event -> event["status"] == "cancelled" end)

    Enum.each(cancelled, &process_cancelled_event(integration, &1))

    context = normalisation_context(integration, calendar_id)

    with {:ok, calendar_events} <- GoogleProvider.normalise_events(active, context) do
      Sync.persist_normalised_events(integration, calendar_events)
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp normalisation_context(integration, calendar_id) do
    %{
      calendar_integration_id: integration.id,
      provider_calendar_id: calendar_id || integration.default_booking_calendar_id || "primary",
      synced_at: DateTime.utc_now(:microsecond)
    }
  end

  defp process_cancelled_event(integration, event) do
    Sync.reconcile_deletions(integration, [
      %{provider_event_id: event["id"], uid: event["iCalUID"]}
    ])
  end

  defp persist_sync_state(integration, next_sync_token) do
    attrs =
      maybe_put_sync_token(%{last_external_sync_at: DateTime.utc_now(:second)}, next_sync_token)

    result = CalendarIntegrationQueries.update_sync_state(integration, attrs)
    HealthCheck.mark_synced_successfully(:calendar, integration.id)

    case result do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist Google Calendar sync state",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        :ok
    end
  end

  defp maybe_put_sync_token(attrs, nil), do: attrs
  defp maybe_put_sync_token(attrs, token), do: Map.put(attrs, :google_sync_token, token)
end
