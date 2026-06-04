defmodule Tymeslot.Workers.RefreshOutlookCalendarWorker do
  @moduledoc """
  Oban worker that performs an on-demand refresh of a single Outlook Calendar
  integration in response to a user-initiated "Refresh now" click.

  Outlook syncs are normally event-driven via Microsoft Graph webhooks; this
  worker is the manual escape hatch when a notification was missed, delayed, or
  never delivered (e.g. WEBHOOK_BASE_URL not configured).

  Mirrors the per-integration logic of
  `FallbackSyncSweepWorker.process_outlook/1`: if the integration has a
  `graph_delta_link`, delta-sync via `OutlookDeltaSync.fetch_and_apply/1`;
  otherwise bootstrap a fresh delta baseline via
  `OutlookCalendarAPI.bootstrap_sync/1` and opportunistically register a
  webhook subscription.

  Broadcasts `SyncBroadcast.broadcast_sync_complete/2` on success so the
  dashboard's progress counter clears.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync, as: OutlookDeltaSync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}}) do
    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, %{provider: "outlook"} = integration} ->
        refresh(integration)

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

  defp refresh(%{graph_delta_link: nil} = integration), do: bootstrap(integration)

  defp refresh(integration) do
    case OutlookDeltaSync.fetch_and_apply(integration) do
      :ok ->
        broadcast_complete(integration)
        :ok

      :error ->
        # DeltaSync clears the stored link on obsolete-endpoint detection (old
        # `events/delta`) or 410 expiry. Reload to see whether that happened —
        # if so, finish the job by bootstrapping rather than relying on an
        # Oban retry to converge on the second pass.
        case CalendarIntegrationQueries.get(integration.id) do
          {:ok, %{graph_delta_link: nil} = reloaded} -> bootstrap(reloaded)
          _other -> {:error, :delta_sync_failed}
        end
    end
  end

  defp bootstrap(integration) do
    case outlook_calendar_api().bootstrap_sync(integration) do
      {:ok, updated} ->
        # Opportunistic webhook (re-)registration. Non-fatal: a seeded delta
        # link is enough on its own, the next click/sweep can keep things current.
        outlook_calendar_api().register_graph_subscription(updated)
        broadcast_complete(updated)
        :ok

      error ->
        Logger.warning("Outlook bootstrap failed during manual refresh",
          calendar_integration_id: integration.id,
          error: inspect(error)
        )

        {:error, :bootstrap_failed}
    end
  end

  defp broadcast_complete(integration) do
    SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
  end

  defp outlook_calendar_api do
    Application.get_env(:tymeslot, :outlook_calendar_api_module, OutlookCalendarAPI)
  end
end
