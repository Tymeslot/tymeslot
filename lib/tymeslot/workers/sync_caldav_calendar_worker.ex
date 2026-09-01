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

    CalendarManagement.flag_for_reconnection(
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

    CalendarManagement.flag_for_reconnection(
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

  # A 5xx is the remote failing, not the request being wrong, so it stays
  # retryable in `Base` — but the retry that matters is the next *cycle*, not
  # the next attempt. The three attempts span under a minute, far too short for
  # a broken server to recover, and a server that 5xxs persistently (as
  # Infomaniak's did for a whole day) exhausts them every cycle and raises a
  # permanent-failure admin alert each time about an outage no operator here
  # can fix. Discard and let the scheduled sync retry minutes later; the health
  # check is what surfaces a remote that never comes back.
  defp handle_sync_result({:error, :server_error}, _integration) do
    {:discard, "CalDAV server returned a server error; the next scheduled sync will retry"}
  end

  # A 4xx there is no talking the request out of (415, 400…, and the modelled
  # `:method_not_allowed`) is the server
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
end
