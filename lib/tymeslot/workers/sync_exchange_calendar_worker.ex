defmodule Tymeslot.Workers.SyncExchangeCalendarWorker do
  @moduledoc """
  Oban worker that runs one sync cycle of an Exchange mailbox
  (`Tymeslot.Integrations.Calendar.Exchange.SyncCycle`, which describes the
  two reads and the incremental item half) and turns its outcome into the
  job's verdict.

  ## Failure handling

  A 401 or 403 means the stored password no longer works or the account may
  not read the mailbox, which no amount of retrying fixes: the integration is
  flagged for reconnection and the job discarded. A 5xx is discarded too; the
  retry that matters is the next scheduled cycle, not three attempts inside a
  minute, and exhausting them raises a permanent-failure alert about an outage
  no operator here can fix. The vocabulary is CalDAV's throughout, because
  `Exchange.Client` answers in it.

  `:circuit_open` is that host's breaker refusing the read because the server
  has already been failing (see `Exchange.Client`). No request was sent, so
  there is no failure to record against the integration and no new sentence to
  show its owner; the job snoozes past the breaker's recovery window instead,
  as the Google and Outlook sync workers do.

  The empty-response guard mirrors `SyncIcsCalendarWorker`'s and is applied
  per role. A successful call that returns nothing is far more likely a bad
  read than a genuinely emptied mailbox once the cache already holds rows, and
  emptying the busy half on that signal is precisely the "fully booked mailbox
  reported as free" outcome this whole design exists to prevent.
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

  # An open breaker or a rate limit is waited out with a snooze, which from
  # Oban 2.24 costs no attempt; without a bound a provider that never
  # recovers would keep this job snoozing for ever, with no alert.
  @max_unavailable_snoozes 12

  require Logger

  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalDAV.Errors, as: CalDAVErrors
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.Exchange.SyncCycle
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.CalendarSyncJob
  alias Tymeslot.Workers.SyncRequest

  @busy_only EventRole.busy_only()

  # Long enough to clear the Exchange breaker's `recovery_timeout` (two
  # minutes, see `CalendarCircuitBreaker`), so the snoozed job wakes to a
  # breaker that will at least let it probe rather than to a second refusal.
  @circuit_open_snooze_seconds 130

  @behaviour ExpectedJobOutcome

  # The integration is gone, or only its owner can fix it by reconnecting.
  # A server error is retried by the next sync, and a refusal is the
  # owner's server configuration.
  @integration_gone "Integration not found"
  @credentials_rejected "Exchange server rejected credentials — reauthentication required"
  @no_mailbox "Exchange integration has no addressable mailbox"
  @server_refused "Exchange server refused the sync request"
  @server_error "Exchange server returned a server error; the next scheduled sync will retry"
  @too_large "Exchange server returned more data than Tymeslot can process at once"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason) when is_binary(reason) do
    reason in [@integration_gone, @credentials_rejected, @no_mailbox, @server_error, @too_large] or
      reason == ReauthHandling.discard_reason() or
      String.starts_with?(reason, @server_refused <> ": ")
  end

  def expected_outcome?(_reason), do: false

  @doc """
  Enqueues a sync of the Exchange integration `integration_id`. A sync
  already waiting runs in its place; one already running runs again once it
  finishes, since it may have read the mailbox before the request (see
  `Tymeslot.Workers.SyncRequest`).
  """
  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(integration_id),
    do: SyncRequest.insert(__MODULE__, %{"calendar_integration_id" => integration_id})

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    CalendarSyncJob.run(job, &(&1 |> SyncCycle.run() |> handle_result(&1)),
      max_snoozes: @max_unavailable_snoozes,
      exhausted_reason: "Exchange server did not recover within the maximum wait"
    )
  end

  # --- Outcomes ---

  defp handle_result(:ok, _integration), do: :ok

  # The server rejected the stored credentials, or will not let this account
  # read the mailbox. Retrying re-sends the same rejected credentials.
  defp handle_result({:error, reason}, integration) when reason in [:unauthorized, :forbidden] do
    Logger.warning("Exchange sync unauthorised; flagging for reconnection",
      calendar_integration_id: integration.id
    )

    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "The Exchange server rejected the stored credentials. Please reconnect the integration."
      ),
      @credentials_rejected
    )
  end

  # `GetUserAvailability` addresses a mailbox, and this integration names none
  # that can be addressed. No retry can invent one; the owner has to supply an
  # address, so the dashboard is told and the job discarded.
  defp handle_result({:error, :no_mailbox_address}, integration) do
    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "Tymeslot needs the mailbox's email address to read its free/busy time. Please reconnect the integration and provide it."
      ),
      @no_mailbox
    )
  end

  # The host's breaker refused the read, so nothing was sent and nothing about
  # this integration changed. Recording a sync error would put the breaker's
  # own refusal in front of the owner as though their mailbox had failed, and
  # retrying immediately would only be refused again.
  defp handle_result({:error, :circuit_open}, integration) do
    Logger.warning("Exchange circuit breaker open; snoozing sync",
      calendar_integration_id: integration.id
    )

    {:snooze, @circuit_open_snooze_seconds}
  end

  # A 5xx is the remote failing, not the request being wrong, but the retry
  # that matters is the next cycle: three attempts span under a minute, far
  # too short for a broken server to recover, and exhausting them raises a
  # permanent-failure alert every cycle about an outage no operator here can
  # fix. Returning `{:unexpected_status, 503}` instead of `:server_error`
  # would land in neither this clause nor the terminal one below, which is why
  # `Exchange.Client` classifies every 5xx before it gets here.
  defp handle_result({:error, :server_error}, integration) do
    record_failure(integration, :server_error)

    {:discard, @server_error}
  end

  # The server answered, past the response budget, for a single item too
  # large on its own (`ItemDiscovery` halves larger batches). Not a refusal:
  # the same item is answered the same way until it leaves the window.
  defp handle_result({:error, :response_too_large}, integration) do
    record_failure(integration, :response_too_large)

    {:discard, @too_large}
  end

  defp handle_result({:error, reason} = result, integration) do
    record_failure(integration, reason)

    if CalDAVErrors.terminal_error?(reason) do
      {:discard, "#{@server_refused}: #{refusal(reason)}"}
    else
      result
    end
  end

  # The failure streak is not recorded here: `perform/1` feeds the whole
  # cycle's verdict to `SyncHealth.record_outcome/2`, and the clauses that
  # flag for reconnection never reach this helper at all. This one owns the
  # message the dashboard shows.
  defp record_failure(integration, reason) do
    Logger.error("Exchange calendar sync failed",
      calendar_integration_id: integration.id,
      error: LogFormat.reason(reason)
    )

    CalendarIntegrationQueries.mark_sync_error(integration, sync_error_message(reason))

    :ok
  end

  # The msgid stored as the integration's `sync_error`, untranslated: the
  # integration card translates it in the owner's locale. Public for the test
  # that pins every writer to a known msgid.
  #
  # The guarded refusal gets its own sentence per half, because the two say
  # very different things to the owner: one means the diary would have been
  # emptied, the other that the grid would have gone blank.
  @doc false
  @spec sync_error_message(term()) :: String.t()
  def sync_error_message({:empty_feed_with_populated_cache, @busy_only}) do
    dgettext_noop(
      "integrations_calendar",
      "Exchange reported no busy time at all, but the cache still holds some. Keeping it in place and retrying rather than treating your diary as free."
    )
  end

  def sync_error_message({:empty_feed_with_populated_cache, _role}) do
    dgettext_noop(
      "integrations_calendar",
      "Exchange returned no calendar events, but the cache still holds some. Keeping them in place and retrying rather than emptying your calendar view."
    )
  end

  def sync_error_message({:soap_fault, _message}) do
    dgettext_noop(
      "integrations_calendar",
      "The Exchange server rejected the request."
    )
  end

  def sync_error_message(:no_response_code) do
    dgettext_noop(
      "integrations_calendar",
      "The Exchange server answered the free/busy request with nothing Tymeslot could read. Retrying rather than treating your diary as free."
    )
  end

  def sync_error_message({:response_code, _code}), do: sync_error_message(:no_response_code)
  def sync_error_message({:free_busy_view_type, _view}), do: sync_error_message(:no_response_code)

  # Everything else is a transport failure `Exchange.Client` named in CalDAV's
  # own vocabulary, so it is worded by the module that owns that vocabulary
  # rather than given a second Exchange-flavoured sentence here.
  def sync_error_message(reason), do: CalDAVErrors.describe_error(reason)

  # The discard reason is what an operator reads on the job record, so it keeps
  # the status the owner-facing sentence in `sync_error` leaves out.
  defp refusal({:unexpected_status, status}), do: "HTTP #{status}"
  defp refusal(reason), do: CalDAVErrors.describe_error(reason)
end
