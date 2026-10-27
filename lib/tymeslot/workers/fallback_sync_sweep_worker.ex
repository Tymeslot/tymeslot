defmodule Tymeslot.Workers.FallbackSyncSweepWorker do
  @moduledoc """
  Oban worker that performs a sweep of all active calendar integrations every
  15 minutes as a fallback mechanism for missed or delayed webhook notifications.

  The sweep itself does no provider I/O: it only fans out a sync job per
  integration that `Tymeslot.Integrations.Calendar.SyncSchedule` says is due,
  with the worker its provider syncs with. Google and Outlook are due on
  every sweep, the net for a missed webhook; CalDAV-family integrations by
  their sync tier; subscriptions and Exchange every 30 minutes.

  CalDAV integrations also get a forced full fetch once a day, to recover
  events their tier's delta reads missed.

  Integrations are read 50 at a time, a page by id per query and no
  transaction around the walk: each page is decided and enqueued before the
  next is read, so the sweep holds one page in memory however many
  integrations there are, and each job is visible as soon as it is
  inserted. Each page's jobs are scheduled one second after the previous
  page's via `scheduled_at`, to avoid thundering-herd load on provider APIs
  and the database without blocking the queue slot.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1,
    # Just under the 15-minute crontab interval: uniqueness counts from the
    # previous job's insertion, so a full 900 would swallow the next slot's
    # job whenever the cron plugin inserts it a moment early.
    unique: [period: 840]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncSchedule
  alias Tymeslot.Integrations.HealthCheck.SyncGating
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @batch_size 50
  @batch_stagger_seconds 1

  # Forced full fetch: every 24 hours to recover events missed by Tier 1/2
  # delta-based optimisations. Was 12 hours before the reconcile transaction
  # was made atomic (see SyncReconciler.process_full_fetch/6) — with the
  # cache now guaranteed to commit cleanly, the safety-net cadence can be
  # slower without increasing the risk of persistent drift.
  @forced_full_fetch_interval_seconds 24 * 3600

  # Spread forced full-fetch jobs over the next 15 minutes to avoid thundering
  # herd on CalDAV servers.
  @forced_full_fetch_jitter_seconds 900

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    paused_ids = SyncGating.paused_integration_ids(:calendar)
    counts = sweep_pages(0, 0, %{}, now, paused_ids)

    Logger.info("FallbackSyncSweep complete",
      google_scheduled: Map.get(counts, :google, 0),
      outlook_scheduled: Map.get(counts, :outlook, 0),
      caldav_scheduled: Map.get(counts, :caldav, 0),
      caldav_skipped: Map.get(counts, :caldav_skipped, 0),
      caldav_forced_full_scheduled: Map.get(counts, :caldav_forced_full, 0),
      caldav_forced_full_conflicts: Map.get(counts, :caldav_forced_full_conflicts, 0),
      subscription_scheduled: Map.get(counts, :subscription, 0),
      exchange_scheduled: Map.get(counts, :exchange, 0),
      paused: Map.get(counts, :paused, 0)
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # One page at a time, by id. Each page is read by its own query and its jobs
  # inserted before the next is read, outside any transaction: an insert made
  # inside one would hold Oban's unique lock for the job until the whole sweep
  # committed, so an owner's Refresh or a webhook enqueue for the same
  # integration would meet it as a conflict and be dropped, and the staggered
  # jobs would stay invisible until the end.
  # ---------------------------------------------------------------------------

  defp sweep_pages(after_id, batch_index, counts, now, paused_ids) do
    case CalendarIntegrationQueries.list_active_page(after_id, @batch_size) do
      [] ->
        counts

      page ->
        counts =
          Map.merge(counts, flush(page, batch_index, now, paused_ids), fn _key, a, b -> a + b end)

        sweep_pages(List.last(page).id, batch_index + 1, counts, now, paused_ids)
    end
  end

  defp flush(page, batch_index, now, paused_ids) do
    {paused, batch} = Enum.split_with(page, &MapSet.member?(paused_ids, &1.id))

    caldav = Enum.filter(batch, &(group(&1) == :caldav))

    # Forced full fetches first, so that for an integration due both a plain
    # sync and a forced full fetch, Oban's unique constraint on
    # SyncCalDavCalendarWorker (keyed by calendar_integration_id) keeps the
    # forced job; the plain enqueue below then conflicts and is not counted.
    {forced, forced_conflicts} = enqueue_caldav_forced_full_fetches(caldav, now)
    due = Enum.filter(batch, &SyncSchedule.due?(&1, now))

    due
    |> Enum.filter(&(enqueue(&1, batch_index, now) == :ok))
    |> Enum.frequencies_by(&group/1)
    |> Map.merge(
      %{
        paused: length(paused),
        caldav_skipped: length(caldav) - Enum.count(due, &(group(&1) == :caldav)),
        caldav_forced_full: forced,
        caldav_forced_full_conflicts: forced_conflicts
      },
      fn _key, left, right -> left + right end
    )
  end

  defp group(%{provider: "google"}), do: :google
  defp group(%{provider: "outlook"}), do: :outlook

  defp group(%{provider: provider}) do
    cond do
      provider in ProviderConfig.caldav_based_provider_strings() -> :caldav
      provider in ProviderConfig.subscription_provider_strings() -> :subscription
      provider in ProviderConfig.ews_provider_strings() -> :exchange
      true -> :other
    end
  end

  # Each batch after the first is scheduled a second after the one before it
  # rather than slept between, for the same pacing against provider APIs and
  # the database without holding the sweep's queue slot.
  defp enqueue(integration, batch_index, now) do
    {:ok, %{worker: worker_module}} = SyncSchedule.schedule(integration)
    args = %{"calendar_integration_id" => integration.id}

    opts =
      if batch_index > 0,
        do: [scheduled_at: DateTime.add(now, batch_index * @batch_stagger_seconds, :second)],
        else: []

    insert(
      worker_module.new(args, opts),
      integration,
      "Failed to enqueue worker in fallback sweep"
    )
  end

  defp insert(changeset, integration, failure) do
    case Oban.insert(changeset) do
      {:ok, %Oban.Job{conflict?: true}} ->
        :conflict

      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(failure,
          worker: changeset.changes.worker,
          calendar_integration_id: integration.id,
          error: reason
        )

        :error
    end
  end

  # ---------------------------------------------------------------------------
  # Periodic forced full fetch (recovers events missed by Tier 1/2 optimisations)
  # ---------------------------------------------------------------------------

  defp enqueue_caldav_forced_full_fetches(integrations, now) do
    integrations
    |> Enum.filter(&forced_full_fetch_due?(&1, now))
    |> Enum.map(fn integration ->
      delay_seconds = :rand.uniform(@forced_full_fetch_jitter_seconds)

      %{"calendar_integration_id" => integration.id, "force_full_fetch" => true}
      |> SyncCalDavCalendarWorker.new(scheduled_at: DateTime.add(now, delay_seconds, :second))
      |> insert(integration, "Failed to enqueue forced full-fetch CalDAV job")
    end)
    |> then(&{Enum.count(&1, fn r -> r == :ok end), Enum.count(&1, fn r -> r == :conflict end)})
  end

  defp forced_full_fetch_due?(%{last_full_sync_at: nil}, _now), do: true

  defp forced_full_fetch_due?(%{last_full_sync_at: last_full_sync_at}, now) do
    cutoff = DateTime.add(now, -@forced_full_fetch_interval_seconds, :second)
    DateTime.before?(last_full_sync_at, cutoff)
  end
end
