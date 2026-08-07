defmodule Tymeslot.Workers.SyncCalDavCalendarWorker do
  @moduledoc """
  Oban worker that syncs a CalDAV calendar integration.

  The protocol work lives in `Tymeslot.Integrations.Calendar.CalDAV.Sync`,
  which reports outcomes without deciding what they mean. This module supplies
  that decision: which failures are worth another attempt, which are permanent
  until someone reconnects, and which need the integration flagged in the
  dashboard first.

  ## Per-integration deduplication

  `unique: [period: 300, keys: [:calendar_integration_id]]` prevents duplicate
  jobs from accumulating when a sweep worker or external trigger enqueues a job
  for an integration that already has one queued or running.

  ## Auth errors (REQ-012)

  A 401 or 403 flags the integration's `needs_reauth` field and returns
  `{:discard, …}` — no retry, since the failure is permanent until the user
  reconnects. If the DB write itself fails the worker returns `{:error, …}` so
  Oban retries and takes another shot at recording the flag. The `is_active`
  flag is left unchanged so the integration stays visible in the dashboard.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Errors, as: CalDAVErrors
  alias Tymeslot.Integrations.Calendar.CalDAV.Sync
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.CalendarManagement

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    integration_id = Map.fetch!(args, "calendar_integration_id")
    force_full_fetch? = Map.get(args, "force_full_fetch", false) == true

    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        integration
        |> Sync.run(force_full_fetch?)
        |> handle_sync_result(integration)

      {:error, :not_found} ->
        Logger.warning("CalDAV integration not found, discarding sync job",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
    end
  end

  defp handle_sync_result(:ok, _integration), do: :ok

  # The server rejected the stored credentials. Retrying re-sends the same
  # rejected credentials, so the only useful action is to ask the owner to
  # reconnect.
  defp handle_sync_result({:error, reason}, integration)
       when reason in [:unauthorized, :forbidden] do
    Logger.warning("CalDAV sync unauthorised; flagging for reauth",
      calendar_integration_id: integration.id
    )

    flag(
      integration,
      dgettext(
        "dashboard_calendar_providers",
        "CalDAV server rejected the stored credentials. Please reconnect the integration."
      ),
      "CalDAV server rejected credentials — reauthentication required"
    )
  end

  # The calendar bookings are written to is gone. Nothing can be synced into it
  # until the owner picks a different one.
  defp handle_sync_result({:error, :booking_calendar_missing}, integration) do
    Logger.warning(
      "CalDAV booking calendar no longer exists; flagging integration for reconnection",
      calendar_integration_id: integration.id
    )

    flag(
      integration,
      dgettext(
        "dashboard_calendar_providers",
        "The booking calendar no longer exists on the CalDAV server. Please reconnect the integration and select a different calendar."
      ),
      "CalDAV booking calendar not found — user action required"
    )
  end

  # The deletion circuit breaker refuses a listing, not an attempt: a retry
  # within the same cycle re-fetches the same data and refuses identically, so
  # retrying costs three times the work for a guaranteed identical outcome and
  # raises a permanent-failure admin alert every cycle. Discard instead — the
  # refusal needs no operator action and resolves itself once the absence is
  # corroborated over time (see `SyncReconciler`'s grace period). The next
  # scheduled sync re-evaluates from scratch.
  defp handle_sync_result({:error, :suspicious_bulk_deletion}, _integration) do
    {:discard, "CalDAV deletion circuit breaker refused a suspicious bulk deletion"}
  end

  # A 4xx the transport layer does not model (415, 405, 400…) is the server
  # refusing the request itself: the remaining attempts re-send the same bytes
  # for the same refusal, then page an operator about a server-side condition
  # no operator action can fix. `Http` has already logged the status and the
  # server's own explanation, and the health check surfaces the integration.
  defp handle_sync_result({:error, reason} = result, _integration) do
    if CalDAVErrors.terminal_error?(reason) do
      {:discard, "CalDAV server refused the sync request: #{CalDAVErrors.describe_error(reason)}"}
    else
      result
    end
  end

  # A failed flag write is worth retrying: without it the dashboard never tells
  # the owner why their calendar stopped syncing.
  defp flag(integration, message, discard_reason) do
    case CalendarManagement.mark_needs_reauth(integration, message) do
      {:ok, _updated} -> {:discard, discard_reason}
      {:error, _changeset} -> {:error, "Failed to flag integration: #{discard_reason}"}
    end
  end
end
