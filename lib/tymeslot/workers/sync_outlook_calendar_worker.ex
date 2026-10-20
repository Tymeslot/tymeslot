defmodule Tymeslot.Workers.SyncOutlookCalendarWorker do
  @moduledoc """
  Oban worker that syncs a single Outlook Calendar event after receiving a
  Microsoft Graph change notification.

  Each job targets one event identified by `graph_resource_id`. The worker
  fetches the event from Graph, upserts it into the local cache, and
  reconciles any linked Tymeslot meeting whose times may have changed.

  On a 404 (event deleted by the user) the cache row is removed and the linked
  meeting (if any) is reconciled with `:deleted`. On 401 the integration is
  flagged for reconnection and the job discarded rather than retried, matching
  REQ-012: no retry can re-authorise a credential Graph has rejected.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 5,
    unique: [
      period: 60,
      keys: [:calendar_integration_id, :graph_resource_id],
      # Only a job still waiting to run absorbs a second notification for the
      # same event: it fetches the event when it runs, so it reads the later
      # change too. One that has fetched already (running or finished) must
      # not swallow it, or a second edit within the minute never reaches the
      # cache.
      states: [:available, :scheduled, :retryable]
    ]

  use Gettext, backend: TymeslotWeb.Gettext

  # An open breaker or a rate limit is waited out with a snooze, which from
  # Oban 2.24 costs no attempt; without a bound a provider that never
  # recovers would keep this job snoozing for ever, with no alert.
  @max_unavailable_snoozes 12

  require Logger

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesMaster
  alias Tymeslot.Integrations.Calendar.SeriesRules
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.CalendarSyncJob
  alias Tymeslot.Workers.RetryHelpers

  # CalendarGrid enqueues Outlook jobs with only calendar_integration_id (no graph_resource_id).
  # Outlook syncs are event-driven via Microsoft Graph webhooks — there is no full-sync path yet.
  # Discard these jobs gracefully rather than crashing.
  @behaviour ExpectedJobOutcome

  # The integration is gone, or only its owner can fix it by reconnecting.
  # A sync without a Graph resource id is a bug, and is recorded.
  @integration_gone "Integration not found"
  @credentials_rejected "Microsoft Graph rejected credentials — reauthentication required"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@integration_gone, @credentials_rejected] or
        reason == ReauthHandling.discard_reason()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id} = args})
      when not is_map_key(args, "graph_resource_id") do
    Logger.warning(
      "SyncOutlookCalendarWorker requires graph_resource_id; discarding calendar-grid-triggered job",
      calendar_integration_id: integration_id
    )

    {:discard, "graph_resource_id required — Outlook syncs are webhook-driven"}
  end

  def perform(
        %Oban.Job{
          args: %{
            "calendar_integration_id" => _integration_id,
            "graph_resource_id" => graph_resource_id
          }
        } =
          job
      ) do
    Logger.metadata(graph_resource_id: graph_resource_id)

    CalendarSyncJob.run(job, &sync_event(&1, graph_resource_id),
      max_snoozes: @max_unavailable_snoozes,
      exhausted_reason: "Outlook Calendar did not recover within the maximum wait"
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp sync_event(integration, graph_resource_id) do
    result =
      Tokens.with_access_token(integration, &OutlookCalendarAPI.refresh_token/1, fn token ->
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
        Logger.warning("Outlook Calendar sync unauthorised; flagging for reauth",
          calendar_integration_id: integration.id,
          graph_resource_id: graph_resource_id
        )

        handle_credentials_rejected(integration)

      {:error, :circuit_open} ->
        Logger.warning("Outlook Calendar circuit breaker open; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, 120}

      {:error, {:rate_limited, message}} ->
        Logger.warning("Outlook Calendar sync rate limited; snoozing",
          calendar_integration_id: integration.id
        )

        {:snooze, min(RetryHelpers.parse_retry_after_from_message(message) || 120, 600)}

      {:error, reason} ->
        Logger.error("Outlook Calendar sync failed",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end

  # Graph is refusing the credentials, not this one event: the 401 is caught
  # ahead of the circuit breaker, and `Tokens.with_access_token/4` has
  # already tried a refresh, so reaching here means the refresh failed or the
  # refreshed token was rejected too. Every other event notification for this
  # integration is about to be refused the same way, and the 15-minute sweep
  # would keep re-queueing them; flagging removes the integration from that
  # population until its owner reconnects. Only the false-to-true transition
  # emails them, and the scheduler's uniqueness window backstops the race
  # between two event jobs flagging at once.
  defp handle_credentials_rejected(integration) do
    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "Microsoft rejected the stored credentials. Please reconnect the integration."
      ),
      @credentials_rejected
    )
  end

  defp handle_event_deleted(integration, graph_resource_id) do
    Logger.info("Outlook Calendar event deleted; removing from cache",
      calendar_integration_id: integration.id,
      graph_resource_id: graph_resource_id
    )

    Sync.reconcile_deletions(integration, [%{provider_event_id: graph_resource_id, uid: nil}])
    stamp_external_sync(integration)
    :ok
  end

  defp handle_event_fetched(integration, graph_resource_id, event) do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: Defaults.booking_calendar_id(integration),
      synced_at: DateTime.utc_now(:microsecond)
    }

    case OutlookProvider.normalise_events([event], context) do
      {:ok, [_cal_event | _rest] = calendar_events} ->
        :ok =
          SeriesRules.refresh(integration.id, calendar_events, SeriesMaster.reader(integration),
            changed: true
          )

        # A cache write that failed is a cycle that did not sync: the job
        # retries and health state counts it, rather than the sync being
        # stamped as done over an event the cache never received.
        case Sync.persist_normalised_events(integration, calendar_events) do
          :ok ->
            stamp_external_sync(integration)
            :ok

          {:error, reason} ->
            Logger.error("Outlook event could not be written to the cache",
              calendar_integration_id: integration.id,
              graph_resource_id: graph_resource_id,
              error: LogFormat.reason(reason)
            )

            {:error, :cache_write_failed}
        end

      {:ok, []} ->
        Logger.warning("Outlook event could not be normalised; skipping",
          calendar_integration_id: integration.id,
          graph_resource_id: graph_resource_id
        )

        stamp_external_sync(integration)
        :ok
    end
  end

  defp stamp_external_sync(integration) do
    case CalendarIntegrationQueries.update_sync_state(integration, %{
           last_external_sync_at: DateTime.utc_now(:second)
         }) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist Outlook Calendar sync state",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(changeset)
        )

        :ok
    end
  end
end
