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

  The selected secondary calendars are read in full each run, over the sync
  window, as is the booking calendar when it bootstraps. Those listings carry
  no deletions, so once a run has read every calendar, the rows the listings
  no longer returned are swept (`Tymeslot.Integrations.Calendar.Google.CacheSweep`).

  Whatever the cycle ends up doing, its verdict is recorded against the
  integration's health state at the job boundary; see
  `Tymeslot.Workers.SyncHealth`.
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
  alias Tymeslot.Integrations.Calendar.Google.CacheSweep
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Workers.SyncHealth
  alias Tymeslot.Workers.SyncRequest

  @doc """
  Enqueues a sync of the Google integration `integration_id`, the one the
  dashboard's Refresh asks for. A sync already waiting for the integration
  runs in its place; one already running runs again once it finishes, since
  it may have read Google before the request (see
  `Tymeslot.Workers.SyncRequest`).
  """
  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(integration_id),
    do: SyncRequest.insert(__MODULE__, %{"calendar_integration_id" => integration_id})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}} = job) do
    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        integration
        |> sync_integration()
        |> tap(&SyncHealth.record_outcome(integration, &1))
        |> SyncRequest.rerun_if_requested(job)

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

  # `started_at` is taken before anything is read from Google: every row this
  # run writes is written after it, which is what lets `CacheSweep` tell the
  # rows a listing returned from the ones it no longer does.
  defp sync_integration(integration) do
    started_at = DateTime.utc_now(:microsecond)

    case Config.google_calendar_api_module().list_events_incremental(integration) do
      {:ok, %{events: events, next_sync_token: next_sync_token}} ->
        Logger.info("Incremental Google Calendar sync fetched events",
          calendar_integration_id: integration.id,
          event_count: length(events)
        )

        process_incremental_sync(integration, events, next_sync_token, {started_at, []})

      {:error, :gone, _message} ->
        Logger.warning(
          "Google Calendar sync token expired; performing full bootstrap resync",
          calendar_integration_id: integration.id
        )

        bootstrap_integration(integration, started_at)

      {:error, :no_sync_token} ->
        Logger.info(
          "Google Calendar integration has no sync token; performing initial bootstrap",
          calendar_integration_id: integration.id
        )

        bootstrap_integration(integration, started_at)

      {:error, :unauthorized, _message} ->
        Logger.warning("Google Calendar sync unauthorised; flagging for reauth",
          calendar_integration_id: integration.id
        )

        handle_credentials_rejected(integration)

      {:error, :not_found, _message} ->
        handle_booking_calendar_missing(integration)

      {:error, :not_a_calendar_user, _message} ->
        handle_calendar_not_enabled(integration)

      {:error, :circuit_open} ->
        Logger.warning("Google Calendar circuit breaker open; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, 120}

      {:error, :too_many_pages, message} ->
        Logger.error(
          "Google Calendar incremental sync exceeded pagination limit; discarding job",
          calendar_integration_id: integration.id,
          error: message
        )

        {:discard, message}

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

  # Unlike a delta, the bootstrap is a complete windowed listing of the
  # booking calendar, so it is swept like a secondary calendar's.
  defp bootstrap_integration(integration, started_at) do
    listed = {booking_calendar_id(integration), CacheSweep.listing_window(DateTime.utc_now())}

    case Config.google_calendar_api_module().bootstrap_sync(integration) do
      {:ok, %{events: events, next_sync_token: next_sync_token}} ->
        Logger.info("Google Calendar bootstrap fetched events",
          calendar_integration_id: integration.id,
          event_count: length(events)
        )

        process_incremental_sync(integration, events, next_sync_token, {started_at, [listed]})

      {:error, :unauthorized, _message} ->
        Logger.warning("Google Calendar bootstrap unauthorised; flagging for reauth",
          calendar_integration_id: integration.id
        )

        handle_credentials_rejected(integration)

      {:error, :not_found, _message} ->
        handle_booking_calendar_missing(integration)

      {:error, :not_a_calendar_user, _message} ->
        handle_calendar_not_enabled(integration)

      {:error, :circuit_open} ->
        Logger.warning("Google Calendar circuit breaker open during bootstrap; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, 120}

      {:error, :too_many_pages, message} ->
        Logger.error(
          "Google Calendar bootstrap exceeded pagination limit; discarding job",
          calendar_integration_id: integration.id,
          error: message
        )

        {:discard, message}

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

  # The sweep runs once every calendar has been read, and only when every
  # one was: a row a calendar's listing no longer returns may be one another
  # calendar of the integration now returns (an event moved between them,
  # its row still filed under the calendar it came from), and that listing
  # rewrites it, which spares it.
  defp process_incremental_sync(integration, events, next_sync_token, {started_at, listed}) do
    with :ok <- safe_process_events(integration, events),
         :ok <- persist_sync_state(integration, next_sync_token),
         {:ok, secondary_listed} <- sync_secondary_calendars(integration) do
      CacheSweep.sweep(integration, listed ++ secondary_listed, started_at)
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
      [] -> {:ok, []}
      ids -> sync_each_secondary_calendar(integration, ids)
    end
  end

  # The calendar the booking calendar's rows are filed under, by the sync
  # token listing and the bootstrap alike (`normalisation_context/2`), and so
  # the one its sweep must name.
  defp booking_calendar_id(integration), do: integration.default_booking_calendar_id || "primary"

  defp selected_secondary_calendar_ids(integration) do
    primary_id = booking_calendar_id(integration)

    integration.calendar_list
    |> Enum.filter(fn cal -> cal.selected == true and cal.id != primary_id end)
    |> Enum.map(& &1.id)
  end

  # Iterates each selected secondary calendar, accumulating the ids of any that
  # no longer exist on Google's side so they can be de-selected in a single write
  # afterwards — preventing a deleted calendar from being re-fetched (and 404ing)
  # on every sync — and the calendars read in full, for the sweep. The
  # accumulator is `{status, missing_ids, listed}`.
  defp sync_each_secondary_calendar(integration, calendar_ids) do
    {start_time, end_time} = window = CacheSweep.listing_window(DateTime.utc_now())

    {status, missing_ids, listed} =
      Enum.reduce_while(calendar_ids, {:ok, [], []}, fn calendar_id, {:ok, missing, listed} ->
        case sync_one_secondary_calendar(integration, calendar_id, start_time, end_time) do
          :listed -> {:cont, {:ok, missing, [{calendar_id, window} | listed]}}
          :skipped -> {:cont, {:ok, missing, listed}}
          :not_found -> {:cont, {:ok, [calendar_id | missing], listed}}
          {:halt, value} -> {:halt, {value, missing, listed}}
        end
      end)

    deselect_missing_calendars(integration, missing_ids)
    if status == :ok, do: {:ok, listed}, else: status
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
          :ok -> :listed
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

        :skipped

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
      dgettext_noop(
        "dashboard_calendar_providers",
        "The booking calendar no longer exists on Google. Please reconnect the integration and choose a different calendar."
      ),
      "Booking calendar not found — user action required"
    )
  end

  # Google is refusing the credentials themselves: either the token refresh
  # failed, so the grant is gone, or a 403 named insufficient permissions.
  # Rate limiting and a Calendar-less account are classified ahead of this in
  # `Google.ApiStatus`, so nothing merely transient lands here
  # and no retry can re-authorise anything.
  #
  # The scheduled probe reaches the same verdict on its own cadence, but not
  # before the 15-minute sweep has re-queued this job repeatedly against a
  # credential Google has already rejected. Flagging here ends that on the
  # first refusal: the sweep's population excludes integrations awaiting
  # reconnection. Flagging twice is harmless — only the false-to-true
  # transition emails the owner.
  defp handle_credentials_rejected(integration) do
    CalendarManagement.flag_for_reconnection(
      integration,
      dgettext(
        "dashboard_calendar_providers",
        "Google rejected the stored credentials. Please reconnect the integration."
      ),
      "Google rejected credentials — reauthentication required"
    )
  end

  # Google answers every call with 403 `notACalendarUser` when the connected
  # account has no Google Calendar (typically a Workspace account whose admin
  # has disabled the service). Retrying cannot recover, so treat it like a
  # missing booking calendar: flag for reconnection and discard.
  defp handle_calendar_not_enabled(integration) do
    Logger.warning(
      "Google account has no Google Calendar; flagging integration for reconnection",
      calendar_integration_id: integration.id
    )

    CalendarManagement.flag_for_reconnection(
      integration,
      dgettext(
        "dashboard_calendar_providers",
        "This Google account doesn't have Google Calendar enabled. Turn on Google Calendar for the account (a Google Workspace administrator may need to do this), or connect a different Google account."
      ),
      "Google Calendar not enabled for account: user action required"
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
  defp safe_process_events(integration, raw_events, calendar_id \\ nil) do
    {cancelled, active} =
      Enum.split_with(raw_events, fn event -> event["status"] == "cancelled" end)

    Sync.reconcile_deletions(integration, Enum.map(cancelled, &cancelled_ref/1))

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
      provider_calendar_id: calendar_id || booking_calendar_id(integration),
      synced_at: DateTime.utc_now(:microsecond)
    }
  end

  # An instance is cached under a uid built from its original start, which a
  # cancellation may not carry; its own id addresses the row exactly.
  defp cancelled_ref(%{"recurringEventId" => series_id} = event) when is_binary(series_id),
    do: %{provider_event_id: event["id"], uid: nil}

  defp cancelled_ref(event), do: %{provider_event_id: event["id"], uid: event["iCalUID"]}

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
