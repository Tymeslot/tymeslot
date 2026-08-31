defmodule Tymeslot.Workers.RefreshOutlookCalendarWorker do
  @moduledoc """
  Oban worker that refreshes a single Outlook Calendar integration.

  Outlook syncs are normally event-driven via Microsoft Graph webhooks; this
  worker covers the cases where that is not enough: a user-initiated
  "Refresh now" click, and the periodic `FallbackSyncSweepWorker`, which
  enqueues one of these jobs per Outlook integration to catch missed,
  delayed, or never-delivered notifications (e.g. WEBHOOK_BASE_URL not
  configured).

  If the integration has a `graph_delta_link`, delta-syncs via
  `OutlookDeltaSync.fetch_and_apply/1`; otherwise bootstraps a fresh delta
  baseline via `OutlookCalendarAPI.bootstrap_sync/1` and opportunistically
  registers a webhook subscription.

  Broadcasts `SyncBroadcast.broadcast_sync_complete/2` on success so the
  dashboard's progress counter clears.

  A failure that is the remote's and has used up every attempt is discarded
  rather than failed, so a passing Graph outage does not raise a permanent
  failure admin alert; see `give_up_or_retry/3`.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 5,
    unique: [
      period: 60,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync, as: OutlookDeltaSync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Progressive backoff: 30s, 90s, 240s, 480s. Graph returns transient 500s
    # and connection timeouts that outlast the default schedule, which retries
    # a job to exhaustion inside ~70 seconds and then alerts an operator about
    # what was a one-minute upstream blip. The four gaps total 14 minutes, so
    # the retries resolve before `FallbackSyncSweepWorker` (every 15 minutes)
    # enqueues the next refresh for the same integration.
    case attempt do
      1 -> 30
      2 -> 90
      3 -> 240
      _later -> 480
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}} = job) do
    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, %{provider: "outlook"} = integration} ->
        refresh(integration, job)

      {:ok, %{provider: provider}} ->
        Logger.warning(
          "RefreshOutlookCalendarWorker called for non-Outlook integration; discarding",
          calendar_integration_id: integration_id,
          provider: provider
        )

        {:discard, "Integration is not Outlook"}

      {:error, :not_found} ->
        Logger.warning("Calendar integration not found; discarding Outlook refresh",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
    end
  end

  defp refresh(%{graph_delta_link: nil} = integration, job), do: bootstrap(integration, job)

  defp refresh(integration, job) do
    case OutlookDeltaSync.fetch_and_apply(integration) do
      :ok ->
        broadcast_complete(integration)
        :ok

      {:error, class} ->
        # DeltaSync clears the stored link on obsolete-endpoint detection (old
        # `events/delta`) or 410 expiry. Reload to see whether that happened —
        # if so, finish the job by bootstrapping rather than relying on an
        # Oban retry to converge on the second pass.
        case CalendarIntegrationQueries.get(integration.id) do
          {:ok, %{graph_delta_link: nil} = reloaded} -> bootstrap(reloaded, job)
          _other -> give_up_or_retry(class, job, :delta_sync_failed)
        end
    end
  end

  defp bootstrap(integration, job) do
    case Config.outlook_calendar_api_module().bootstrap_sync(integration) do
      {:ok, updated} ->
        # Opportunistic webhook (re-)registration. Non-fatal: a seeded delta
        # link is enough on its own, the next click/sweep can keep things current.
        Config.outlook_calendar_api_module().register_graph_subscription(updated)
        broadcast_complete(updated)
        :ok

      error ->
        Logger.warning("Outlook bootstrap failed during manual refresh",
          calendar_integration_id: integration.id,
          error: inspect(error)
        )

        give_up_or_retry(error_class(error), job, :bootstrap_failed)
    end
  end

  # A transient Graph failure that has spent the whole retry ladder is not an
  # operator's problem: `FallbackSyncSweepWorker` re-enqueues this integration
  # within 15 minutes, and a remote that never comes back is surfaced by the
  # health check rather than by one discarded job. Discarding keeps a passing
  # upstream blip out of the admin alerts; the underlying status and reason are
  # already logged by whichever call failed. Anything `:hard` — bad credentials,
  # a failed local write — keeps failing loudly.
  defp give_up_or_retry(:transient, %Oban.Job{attempt: attempt, max_attempts: max_attempts}, _rsn)
       when attempt >= max_attempts do
    {:discard, "Outlook sync failed transiently; the next scheduled sweep will retry"}
  end

  defp give_up_or_retry(_class, _job, reason), do: {:error, reason}

  defp error_class({:error, type, _message}) when is_atom(type),
    do: ErrorAnalysis.classify_error(type)

  defp error_class({:error, reason}), do: ErrorAnalysis.classify_error(reason)
  defp error_class(_other), do: :hard

  defp broadcast_complete(integration) do
    SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
  end
end
