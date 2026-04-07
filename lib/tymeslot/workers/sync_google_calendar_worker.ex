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
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Tymeslot.DatabaseQueries.CalendarEventCacheQueries
  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleCalendarAPI
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Meetings.MeetingQueries

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
          "Google Calendar sync token expired; re-registering push channel for full resync",
          calendar_integration_id: integration.id
        )

        case google_calendar_api().register_push_channel(integration) do
          {:ok, _updated} ->
            :ok

          {:error, :webhook_base_url_not_configured} ->
            Logger.warning("Webhook base URL not configured; skipping channel re-registration",
              calendar_integration_id: integration.id
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to re-register Google Calendar push channel",
              calendar_integration_id: integration.id,
              error: inspect(reason)
            )

            {:error, reason}
        end

      {:error, :no_sync_token} ->
        Logger.warning(
          "Google Calendar integration has no sync token; re-registering push channel",
          calendar_integration_id: integration.id
        )

        case google_calendar_api().register_push_channel(integration) do
          {:ok, _updated} ->
            :ok

          {:error, :webhook_base_url_not_configured} ->
            Logger.warning(
              "Webhook base URL not configured; skipping channel re-registration",
              calendar_integration_id: integration.id
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end

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
            case safe_process_events(integration, events) do
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

  # Best-effort: process all events even if individual upserts fail.
  # process_cached_event already logs per-event failures, so we don't halt
  # the batch on the first error — remaining events still get synced.
  defp safe_process_events(integration, events) do
    Enum.each(events, fn event -> process_event(integration, event) end)
    :ok
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp process_event(integration, %{"status" => "cancelled"} = event) do
    uid = event["iCalUID"]
    provider_event_id = event["id"]

    Sync.reconcile(integration.id, provider_event_id, uid, :deleted)
    CalendarEventCacheQueries.delete_by_uid(integration.id, uid)
    :ok
  end

  defp process_event(integration, event) do
    attrs = build_cache_attrs(integration.id, event)
    log = [calendar_integration_id: integration.id, provider_event_id: event["id"]]

    SyncBroadcast.process_cached_event(integration.user_id, attrs, log, fn ->
      maybe_reconcile_time_change(integration, event)
    end)
  end

  defp maybe_reconcile_time_change(integration, event) do
    provider_event_id = event["id"]

    case MeetingQueries.get_by_provider_event_id(integration.id, provider_event_id) do
      {:ok, meeting} ->
        event_start = parse_datetime(event["start"])

        if time_changed?(meeting.start_time, event_start) do
          Sync.reconcile(integration.id, provider_event_id, event["iCalUID"], :modified)
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

  defp build_cache_attrs(integration_id, event) do
    %{
      uid: event["iCalUID"],
      calendar_integration_id: integration_id,
      provider_event_id: event["id"],
      title: event["summary"],
      start_at: parse_datetime(event["start"]),
      end_at: parse_datetime(event["end"]),
      all_day:
        Map.has_key?(event["start"] || %{}, "date") &&
          !Map.has_key?(event["start"] || %{}, "dateTime"),
      location: event["location"],
      description: event["description"],
      attendees:
        Enum.map(event["attendees"] || [], fn attendee ->
          %{
            "email" => attendee["email"],
            "name" => attendee["displayName"],
            "status" => attendee["responseStatus"]
          }
        end),
      recurrence_rule: List.first(event["recurrence"] || []),
      recurring_event_id: event["recurringEventId"],
      status: event["status"],
      raw_data: event,
      etag: event["etag"],
      synced_at: DateTime.utc_now(:second)
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(time_map) when is_map(time_map) do
    cond do
      datetime_str = Map.get(time_map, "dateTime") ->
        parse_iso8601(datetime_str)

      date_str = Map.get(time_map, "date") ->
        parse_date_as_midnight_utc(date_str)

      true ->
        nil
    end
  end

  defp parse_iso8601(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      {:error, _reason} -> nil
    end
  end

  defp parse_date_as_midnight_utc(str) do
    case Date.from_iso8601(str) do
      {:ok, date} ->
        date
        |> DateTime.new!(~T[00:00:00], "Etc/UTC")
        |> DateTime.truncate(:second)

      {:error, _reason} ->
        nil
    end
  end

  defp persist_sync_state(integration, next_sync_token) do
    attrs =
      maybe_put_sync_token(%{last_external_sync_at: DateTime.utc_now(:second)}, next_sync_token)

    case CalendarIntegrationQueries.update_sync_state(integration, attrs) do
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
