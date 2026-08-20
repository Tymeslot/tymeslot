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

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
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

  defp sync_integration(integration) do
    case Config.google_calendar_api_module().list_events_incremental(integration) do
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

      {:error, :not_found, _message} ->
        handle_booking_calendar_missing(integration)

      {:error, :circuit_open} ->
        Logger.warning("Google Calendar circuit breaker open; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, 120}

      {:error, _type, reason} ->
        Logger.error("Google Calendar incremental sync failed",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}

      {:error, reason} ->
        Logger.error("Google Calendar incremental sync failed",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp bootstrap_integration(integration) do
    case Config.google_calendar_api_module().bootstrap_sync(integration) do
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

      {:error, :not_found, _message} ->
        handle_booking_calendar_missing(integration)

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

      {:error, reason} ->
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
    case selected_secondary_calendar_ids(integration) do
      [] -> :ok
      ids -> sync_each_secondary_calendar(integration, ids)
    end
  end

  defp selected_secondary_calendar_ids(integration) do
    primary_id = integration.default_booking_calendar_id || "primary"

    integration.calendar_list
    |> Enum.filter(fn cal -> cal.selected == true and cal.id != primary_id end)
    |> Enum.map(& &1.id)
  end

  # Iterates each selected secondary calendar, accumulating the ids of any that
  # no longer exist on Google's side so they can be de-selected in a single write
  # afterwards — preventing a deleted calendar from being re-fetched (and 404ing)
  # on every sync. The accumulator is `{status, missing_ids}`.
  defp sync_each_secondary_calendar(integration, calendar_ids) do
    now = DateTime.utc_now()
    start_time = DateTime.add(now, -@sync_window_past_days, :day)
    end_time = DateTime.add(now, @sync_window_future_days, :day)

    {status, missing_ids} =
      Enum.reduce_while(calendar_ids, {:ok, []}, fn calendar_id, {:ok, missing} ->
        case sync_one_secondary_calendar(integration, calendar_id, start_time, end_time) do
          :ok -> {:cont, {:ok, missing}}
          :not_found -> {:cont, {:ok, [calendar_id | missing]}}
          {:halt, value} -> {:halt, {value, missing}}
        end
      end)

    deselect_missing_calendars(integration, missing_ids)
    status
  end

  defp sync_one_secondary_calendar(integration, calendar_id, start_time, end_time) do
    case Config.google_calendar_api_module().list_events(
           integration,
           calendar_id,
           start_time,
           end_time
         ) do
      {:ok, events} ->
        case safe_process_events(integration, events, calendar_id) do
          :ok -> :ok
          error -> {:halt, error}
        end

      {:error, :not_found, _message} ->
        Logger.warning("Google Calendar secondary calendar not found; de-selecting",
          calendar_integration_id: integration.id,
          calendar_id: calendar_id
        )

        :not_found

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

        :ok

      {:error, _type, reason} ->
        Logger.error("Google Calendar secondary sync failed",
          calendar_integration_id: integration.id,
          calendar_id: calendar_id,
          error: inspect(reason)
        )

        {:halt, {:error, reason}}

      {:error, reason} ->
        Logger.error("Google Calendar secondary sync failed",
          calendar_integration_id: integration.id,
          calendar_id: calendar_id,
          error: inspect(reason)
        )

        {:halt, {:error, reason}}
    end
  end

  # A 404 on the booking calendar itself means the calendar the user books
  # into was deleted on Google's side. Retrying cannot recover, and the
  # fallback sweep would re-enqueue the job forever — so flag the integration
  # for reconnection (which also removes it from the sweep) and discard.
  defp handle_booking_calendar_missing(integration) do
    Logger.warning(
      "Google Calendar booking calendar no longer exists; flagging integration for reconnection",
      calendar_integration_id: integration.id
    )

    CalendarManagement.flag_for_reconnection(
      integration,
      dgettext(
        "dashboard_calendar_providers",
        "The booking calendar no longer exists on Google. Please reconnect the integration and choose a different calendar."
      ),
      "Booking calendar not found — user action required"
    )
  end

  defp deselect_missing_calendars(_integration, []), do: :ok

  defp deselect_missing_calendars(integration, missing_ids) do
    case CalendarIntegrationQueries.deselect_calendars(integration, missing_ids) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to de-select missing Google calendars",
          calendar_integration_id: integration.id,
          calendar_ids: missing_ids,
          error: inspect(changeset.errors)
        )

        :ok
    end
  end

  # Best-effort: normalise all events via the provider, then delegate to
  # the shared persistence pipeline in `Sync`. Cancelled events are handled
  # separately — they are deleted from the cache and reconciled as deletions.
  #
  # A cancelled *occurrence* of a recurring series is deliberately not one of
  # them, and the distinction is `recurringEventId`. Under `singleEvents=true`
  # every occurrence shares the master's `iCalUID`, and the deletion path
  # withdraws by uid — so routing a cancelled occurrence there deleted the
  # series' only cache row and enqueued a withdrawal of the entire placeholder,
  # removing every occurrence still happening in order to free the one that is
  # not. Measured on a live calendar: cancelling one of five occurrences left
  # the other four unmirrored.
  #
  # What it needs instead is an EXDATE at its own instant, which is a property
  # of the occurrence rather than of the series, and is therefore read where
  # per-instance markers still exist — `Sync.post_commit_reconciliation/2`, over
  # the uncollapsed batch, by `SyncLink.MovedOccurrence`. So it stays with the
  # active events and is normalised: the normaliser already maps `"cancelled"`
  # to `:cancelled`, and `CalendarEvent.blocking?/1` already reads that status,
  # so the cached row stops blocking availability without being removed.
  defp safe_process_events(integration, raw_events, calendar_id \\ nil) do
    {cancelled, active} = Enum.split_with(raw_events, &withdrawn?/1)

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

  # A cancelled event that names no series is gone outright and is withdrawn. One
  # that names a series is a single occurrence of something that still exists,
  # and withdrawing it would take the rest of the series with it.
  defp withdrawn?(%{"status" => "cancelled"} = event),
    do: not is_binary(event["recurringEventId"])

  defp withdrawn?(_event), do: false

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
