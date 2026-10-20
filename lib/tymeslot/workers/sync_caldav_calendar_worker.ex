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
  for an integration that already has one queued or running. A requested full
  fetch (`enqueue_full_fetch/1`) is the exception that is not absorbed: it
  upgrades a waiting job, or makes a running one run again, see
  `Tymeslot.Workers.SyncRequest`.

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

  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Integrations.Calendar.CalDAV.Errors, as: CalDAVErrors
  alias Tymeslot.Integrations.Calendar.CalDAV.Sync
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.CalendarSyncJob
  alias Tymeslot.Workers.SyncRequest

  # Without one Oban lets a job run for ever. A sync is the offline queue's
  # bounded replay (see `CalDAV.OfflineQueue`) followed by the pull; this is
  # far above what either needs, and only ends a job that is truly stuck.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @doc """
  Enqueues a full fetch of the CalDAV integration `integration_id`, the sync
  the dashboard's Refresh asks for: every calendar is read in full rather
  than by delta, so a change the delta would not report (or a cached row
  removed on purpose) comes back. A sync already waiting for the
  integration runs in its place, as a full fetch; one already running runs
  again as a full fetch once it finishes, since it may have read the server
  before the request (see `Tymeslot.Workers.SyncRequest`).
  """
  @spec enqueue_full_fetch(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_full_fetch(integration_id) do
    SyncRequest.insert(__MODULE__, %{
      "calendar_integration_id" => integration_id,
      "force_full_fetch" => true
    })
  end

  @behaviour ExpectedJobOutcome

  # The integration is gone, or only its owner can fix it by reconnecting.
  # A server error or a server that never answered is retried by the next sync. The deletion circuit breaker
  # refusing a sync is recorded.
  @integration_gone "Integration not found"
  @credentials_rejected "CalDAV server rejected credentials — reauthentication required"
  @calendar_gone "CalDAV booking calendar not found — user action required"
  @no_calendar "CalDAV integration has no calendar selected — user action required"
  @server_error "CalDAV server returned a server error; the next scheduled sync will retry"
  @server_unreachable "CalDAV server did not respond; the next scheduled sync will retry"
  @too_large "CalDAV server returned more data than Tymeslot can process at once"
  @free_busy_unreadable "A CalDAV calendar shared as busy times only could not be read; its last busy times are kept and the next scheduled sync will retry"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [
        @integration_gone,
        @credentials_rejected,
        @calendar_gone,
        @no_calendar,
        @server_error,
        @server_unreachable,
        @too_large,
        @free_busy_unreadable
      ] or reason == ReauthHandling.discard_reason()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    force_full_fetch? = Map.get(args, "force_full_fetch", false) == true
    CalendarSyncJob.run(job, &sync(&1, force_full_fetch?))
  end

  defp sync(integration, force_full_fetch?) do
    integration
    |> Sync.run(force_full_fetch?)
    |> tap(&record_failure(integration, &1))
    |> handle_sync_result(integration)
  end

  # Every clause below that discards is a failure no operator or user would
  # otherwise hear about, which is why the verdict they produce is fed to
  # `SyncHealth.record_outcome/2` above rather than dropped; see that module
  # for why both halves belong at the job boundary. Clearing the streak used to
  # live in `CalDAV.Sync.State.put/2` instead, which runs once per calendar
  # path and per tier step, so a healthy first calendar wiped the streak a
  # failing second calendar was accumulating and the badge stayed green through
  # an indefinite outage.
  defp handle_sync_result(:ok, _integration), do: :ok

  # The server rejected the stored credentials. Retrying re-sends the same
  # rejected credentials, so the only useful action is to ask the owner to
  # reconnect.
  defp handle_sync_result({:error, reason}, integration)
       when reason in [:unauthorized, :forbidden] do
    Logger.warning("CalDAV sync unauthorised; flagging for reauth",
      calendar_integration_id: integration.id
    )

    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "CalDAV server rejected the stored credentials. Please reconnect the integration."
      ),
      @credentials_rejected
    )
  end

  # The calendar bookings are written to is gone. Nothing can be synced into it
  # until the owner picks a different one.
  defp handle_sync_result({:error, :booking_calendar_missing}, integration) do
    Logger.warning(
      "CalDAV booking calendar no longer exists; flagging integration for reconnection",
      calendar_integration_id: integration.id
    )

    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "The booking calendar no longer exists on the CalDAV server. Please reconnect the integration and select a different calendar."
      ),
      @calendar_gone
    )
  end

  # No calendar is selected, so there is nothing to sync into. This used to
  # return :ok, which reported a successful sync of nothing: the failure streak
  # reset every cycle, no badge or notification ever fired, and the fallback
  # sweep re-enqueued the same no-op indefinitely because the timestamps it
  # keys off never advanced. Flagging it stops the loop, since the sweep's
  # population excludes integrations awaiting reconnection.
  defp handle_sync_result({:error, :no_calendar_paths}, integration) do
    Logger.warning(
      "CalDAV integration has no calendar selected; flagging integration for reconnection",
      calendar_integration_id: integration.id
    )

    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "No calendar is selected for this integration, so nothing can be synced. Please reconnect the integration and select a calendar."
      ),
      @no_calendar
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
  defp handle_sync_result({:error, reason}, _integration)
       when reason in [:server_error, :service_unavailable] do
    {:discard, @server_error}
  end

  # The remote never answered: a read that timed out, a connection that failed,
  # or a server that took the connection and then went quiet. Same shape as the
  # 5xx above (the remote's condition, not the request's), and `Base` has
  # already retried the transport once with backoff before this. What Oban's
  # remaining attempts add is the same request against the same unreachable
  # host inside a single minute, ending in a permanent-failure alert about an
  # outage no operator here can act on: a host that was down for an hour
  # produced one such alert per sync cycle. Discard, and let the scheduled
  # sync pick the server up when it comes back; a server that stays away is
  # what the health check is for.
  defp handle_sync_result({:error, reason}, _integration)
       when reason in [:timeout, :server_unresponsive, :network_error] do
    {:discard, @server_unreachable}
  end

  # The server answered, past the read's byte budget. Retrying downloads the
  # same answer, and it is the size of the owner's calendar rather than a
  # fault an operator could fix, so it is an expected end of the job. The
  # health check surfaces the integration.
  defp handle_sync_result({:error, :response_too_large}, _integration),
    do: {:discard, @too_large}

  # A calendar shared as busy times only that would not answer its
  # free-busy-query. Never a reason to reconnect: a 403 there means the share
  # changed, and discovery is what drops a calendar that is gone. Its last
  # busy times stay cached; the next cycle asks again.
  defp handle_sync_result({:error, {:free_busy_unreadable, _reason}}, _integration),
    do: {:discard, @free_busy_unreadable}

  # A 4xx there is no talking the request out of (415, 400…, and the modelled
  # `:method_not_allowed`) is the server
  # refusing the request itself: the remaining attempts re-send the same bytes
  # for the same refusal, then page an operator about a server-side condition
  # no operator action can fix. `Http` has already logged the status and the
  # server's own explanation, and the health check surfaces the integration.
  defp handle_sync_result({:error, reason} = result, _integration) do
    if CalDAVErrors.terminal_error?(reason) do
      {:discard, "CalDAV server refused the sync request: #{refusal(reason)}"}
    else
      result
    end
  end

  # The failures that flag the integration for reconnection record their own
  # reason with the flag, and the deletion breaker's refusal resolves itself
  # without the owner. Every other failure is stored as the owner-facing
  # sentence, which the integration card shows while the sync is unhealthy.
  # A successful cycle clears it in `SyncHealth.record_outcome/2`.
  @recorded_elsewhere [
    :unauthorized,
    :forbidden,
    :booking_calendar_missing,
    :no_calendar_paths,
    :suspicious_bulk_deletion
  ]

  defp record_failure(integration, {:error, reason}) when reason not in @recorded_elsewhere do
    CalendarIntegrationQueries.mark_sync_error(integration, CalDAVErrors.describe_error(reason))
  end

  defp record_failure(_integration, _result), do: :ok

  # The discard reason is what an operator reads on the job record, so it keeps
  # the status the owner-facing sentence leaves out.
  defp refusal({:unexpected_status, status}), do: "HTTP #{status}"
  defp refusal(reason), do: CalDAVErrors.describe_error(reason)
end
