defmodule Tymeslot.Workers.RefreshOutlookCalendarWorker do
  @moduledoc """
  Oban worker that refreshes a single Outlook Calendar integration
  (`Tymeslot.Integrations.Calendar.Outlook.SyncCycle`) and turns the outcome
  into the job's verdict.

  Outlook syncs are normally event-driven via Microsoft Graph webhooks; this
  worker covers the cases where that is not enough: a user-initiated
  "Refresh now" click, and the periodic `FallbackSyncSweepWorker`, which
  enqueues one of these jobs per Outlook integration to catch missed,
  delayed, or never-delivered notifications (e.g. WEBHOOK_BASE_URL not
  configured).

  Refused credentials flag the integration for reconnection. A failure that
  is the remote's and has used up every attempt is discarded rather than
  failed, so a passing Graph outage does not raise a permanent failure admin
  alert; see `give_up_or_retry/3`.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 5,
    unique: [
      period: 60,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Outlook.SyncCycle
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.CalendarSyncJob
  alias Tymeslot.Workers.SyncRequest

  @behaviour ExpectedJobOutcome

  # The integration is gone, or only its owner can fix it by reconnecting.
  # A transient failure is retried by the next sweep. A job for an integration
  # that is not Outlook is a bug, and is recorded.
  @integration_gone "Integration not found"
  @transient "Outlook sync failed transiently; the next scheduled sweep will retry"
  @credentials_rejected "Microsoft Graph rejected credentials — reauthentication required"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@integration_gone, @transient, @credentials_rejected] or
        reason == ReauthHandling.discard_reason()

  @doc """
  Enqueues a refresh of the Outlook integration `integration_id`, the one
  the dashboard's Refresh asks for. A refresh already waiting for the
  integration runs in its place; one already running runs again once it
  finishes, since it may have read Outlook before the request (see
  `Tymeslot.Workers.SyncRequest`).
  """
  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(integration_id),
    do: SyncRequest.insert(__MODULE__, %{"calendar_integration_id" => integration_id})

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
  def perform(%Oban.Job{} = job),
    do: CalendarSyncJob.run(job, &refresh(&1, job), provider: "outlook")

  defp refresh(integration, job) do
    case SyncCycle.run(integration) do
      :ok -> :ok
      {:error, :unauthorized} -> handle_credentials_rejected(integration)
      {:error, {stage, class}} -> give_up_or_retry(class, job, stage)
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
    {:discard, @transient}
  end

  defp give_up_or_retry(_class, _job, reason), do: {:error, reason}

  # Retrying a refused credential cannot help; only the owner reconnecting can.
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
end
