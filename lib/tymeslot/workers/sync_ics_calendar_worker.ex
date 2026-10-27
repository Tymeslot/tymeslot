defmodule Tymeslot.Workers.SyncIcsCalendarWorker do
  @moduledoc """
  Oban worker that refreshes a subscribed calendar feed into the local event
  cache (`Tymeslot.Integrations.Calendar.Ics.SyncCycle`) and turns the
  outcome into the job's verdict.

  A 401 or 403 means the feed URL has been revoked or rotated, which no
  amount of retrying will fix: the integration is flagged `needs_reauth` and
  the job discarded so the user is prompted to paste a fresh link. Everything
  else records a sync error and retries.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Ics.Feed
  alias Tymeslot.Integrations.Calendar.Ics.SyncCycle
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.CalendarSyncJob
  alias Tymeslot.Workers.SyncRequest

  @doc """
  Enqueues a feed refresh for the subscription `integration_id`. A refresh
  already waiting runs in its place; one already running runs again once it
  finishes, since it may have fetched the feed before the request (see
  `Tymeslot.Workers.SyncRequest`).
  """
  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(integration_id),
    do: SyncRequest.insert(__MODULE__, %{"calendar_integration_id" => integration_id})

  @behaviour ExpectedJobOutcome

  # The integration is gone, or only its owner can fix it by reconnecting.
  # A subscription without a feed URL is recorded.
  @integration_gone "Integration not found"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do: reason in [@integration_gone] or reason == ReauthHandling.discard_reason()

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: CalendarSyncJob.run(job, &sync/1)

  defp sync(integration) do
    case SyncCycle.run(integration) do
      :ok ->
        :ok

      {:error, :unauthorised} ->
        Management.handle_reauth_required(integration, cause: :rejected_subscription_url)

      {:error, :missing_url} ->
        Logger.error("Calendar subscription has no feed URL stored",
          calendar_integration_id: integration.id
        )

        {:discard, "Subscription has no feed URL"}

      {:error, reason} ->
        record_failure(integration, reason)
    end
  end

  # The failure streak is not recorded here: `perform/1` feeds the whole
  # cycle's verdict to `SyncHealth.record_outcome/2`, and the revoked-URL and
  # missing-URL clauses never reach this helper. This one owns the message the
  # dashboard shows.
  defp record_failure(integration, reason) do
    Logger.error("Calendar subscription sync failed",
      calendar_integration_id: integration.id,
      error: LogFormat.reason(reason)
    )

    CalendarIntegrationQueries.mark_sync_error(integration, Feed.sync_error_message(reason))

    {:error, reason}
  end
end
