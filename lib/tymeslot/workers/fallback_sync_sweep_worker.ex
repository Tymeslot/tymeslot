defmodule Tymeslot.Workers.FallbackSyncSweepWorker do
  @moduledoc """
  Oban worker that performs a sweep of all active calendar integrations every
  15 minutes as a fallback mechanism for missed or delayed webhook notifications.

  The sweep itself does no provider I/O — it only fans out per-integration
  jobs:

  - **Google** — enqueues a `SyncGoogleCalendarWorker` job per integration.
  - **Outlook** — enqueues a `RefreshOutlookCalendarWorker` job per
    integration, which delta-syncs from the stored `graph_delta_link` or
    bootstraps a fresh delta baseline (and opportunistically registers a
    Graph webhook subscription) when no link is stored yet.
  - **CalDAV / Radicale / Nextcloud / Zimbra** — enqueues a `SyncCalDavCalendarWorker`
    job at a frequency determined by the integration's sync tier:
    - Tier 1 (sync-token delta): every 15 minutes
    - Tier 2 (CTag check): every 30 minutes
    - Tier 3 (full fetch): every hour
    - Undetected (nil): every 15 minutes (detect tier ASAP)
  - **Calendar subscriptions (`ics_url`)** — enqueues a `SyncIcsCalendarWorker`
    job every 30 minutes. There is no tier to detect: a published feed offers
    no delta mechanism, so every run is a full fetch, and the publisher
    regenerates the file on its own schedule anyway. Polling harder would cost
    a third party bandwidth for data that has not changed.
  - **Exchange (`exchange`)** — enqueues a `SyncExchangeCalendarWorker` job
    every 30 minutes. EWS offers a delta mechanism (`SyncFolderItems`) that
    this phase does not use, so each run re-reads the whole window through
    both of the provider's reads. This branch is what makes Exchange sync at
    all on a schedule: manual refresh goes through `CalendarGrid` and would
    keep working without it, so its absence shows up only as staleness.

  Jobs are enqueued in batches of 50, each batch scheduled one second after
  the previous via `scheduled_at`, to avoid thundering-herd load on provider
  APIs and the database without blocking the queue slot.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1,
    unique: [period: 900]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.HealthCheck.SyncGating
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncExchangeCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  @batch_size 50
  @batch_stagger_seconds 1

  # Sync interval per CalDAV tier (in seconds).
  # Tier 1 and 2 are lightweight; Tier 3 does a full fetch every time.
  @caldav_tier_intervals %{
    1 => 900,
    2 => 1_800,
    3 => 3_600
  }
  @caldav_default_interval 900

  # Subscribed feeds have no tier: every run is a full fetch of a file the
  # publisher regenerates on its own schedule.
  @subscription_interval 1_800

  # Exchange has no tier either: this phase reads the whole window every run,
  # twice over (free/busy for availability, items for the grid).
  @exchange_interval 1_800

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
    paused_ids = SyncGating.paused_integration_ids(:calendar)
    by_provider = drop_paused_integrations(collect_integrations_by_provider(), paused_ids)

    google_count = enqueue_batched(Map.get(by_provider, "google", []), SyncGoogleCalendarWorker)

    outlook_count =
      enqueue_batched(Map.get(by_provider, "outlook", []), RefreshOutlookCalendarWorker)

    caldav_providers = Enum.map(ProviderConfig.caldav_based_providers(), &Atom.to_string/1)
    caldav_integrations = Enum.flat_map(caldav_providers, &Map.get(by_provider, &1, []))

    # Enqueue forced full-fetch jobs first so that, for integrations needing
    # both a normal sync and a forced full fetch, Oban's unique constraint on
    # SyncCalDavCalendarWorker (keyed by calendar_integration_id) keeps the
    # forced job rather than deduping it to a plain sync.
    # The subsequent normal enqueue pass will hit Oban's unique conflict for
    # those same integrations and be silently ignored, which is the desired
    # outcome.
    {forced_full_count, forced_full_conflicts} =
      enqueue_caldav_forced_full_fetches(caldav_integrations)

    due_integrations = Enum.filter(caldav_integrations, &caldav_due?/1)
    caldav_count = enqueue_batched(due_integrations, SyncCalDavCalendarWorker)
    caldav_skipped = length(caldav_integrations) - length(due_integrations)

    subscription_count = enqueue_due_subscriptions(by_provider)
    exchange_count = enqueue_due_exchange(by_provider)

    Logger.info("FallbackSyncSweep complete",
      google_scheduled: google_count,
      outlook_scheduled: outlook_count,
      caldav_scheduled: caldav_count,
      caldav_skipped: caldav_skipped,
      caldav_forced_full_scheduled: forced_full_count,
      caldav_forced_full_conflicts: forced_full_conflicts,
      subscription_scheduled: subscription_count,
      exchange_scheduled: exchange_count
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Integration loading (streamed to avoid unbounded memory)
  # ---------------------------------------------------------------------------

  defp collect_integrations_by_provider do
    CalendarIntegrationQueries.stream_all_active(@batch_size, %{}, fn integration, acc ->
      Map.update(acc, integration.provider, [integration], &[integration | &1])
    end)
  end

  # Drop integrations whose health state indicates sustained hard failures
  # (typically `invalid_grant` after a revoked token). They stay in the DB
  # with `is_active = true` so the dashboard still shows them, but periodic
  # sync stops hammering them until the next successful health check clears
  # the failure counter — which will only happen after the user reauthorises.
  defp drop_paused_integrations(by_provider, paused_ids) do
    if MapSet.size(paused_ids) == 0 do
      by_provider
    else
      Map.new(by_provider, fn {provider, integrations} ->
        kept = Enum.reject(integrations, fn i -> MapSet.member?(paused_ids, i.id) end)

        if length(kept) < length(integrations) do
          Logger.info("Sync gating paused integrations in fallback sweep",
            provider: provider,
            paused_count: length(integrations) - length(kept)
          )
        end

        {provider, kept}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Shared batch processing
  # ---------------------------------------------------------------------------

  defp process_in_batches(items, per_item_fun) do
    items
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index()
    |> Enum.reduce({0, 0}, fn {batch, batch_index}, {total, conflicts} ->
      {batch_count, batch_conflicts} =
        Enum.reduce(batch, {0, 0}, fn item, {count, confl} ->
          case per_item_fun.(item, batch_index) do
            :ok -> {count + 1, confl}
            :conflict -> {count, confl + 1}
            :error -> {count, confl}
          end
        end)

      {total + batch_count, conflicts + batch_conflicts}
    end)
  end

  defp enqueue_batched(integrations, worker_module) do
    now = DateTime.utc_now()

    {scheduled, _conflicts} =
      process_in_batches(integrations, fn integration, batch_index ->
        args = %{"calendar_integration_id" => integration.id}

        # Stagger each batch by scheduled_at offset instead of sleeping
        # between batches — same thundering-herd pacing without blocking
        # the sweep's queue slot.
        opts =
          if batch_index > 0 do
            [scheduled_at: DateTime.add(now, batch_index * @batch_stagger_seconds, :second)]
          else
            []
          end

        case Oban.insert(worker_module.new(args, opts)) do
          {:ok, %Oban.Job{conflict?: true}} ->
            :conflict

          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to enqueue worker in fallback sweep",
              worker: worker_module,
              calendar_integration_id: integration.id,
              error: reason
            )

            :error
        end
      end)

    scheduled
  end

  # ---------------------------------------------------------------------------
  # Subscribed feed scheduling
  # ---------------------------------------------------------------------------

  defp enqueue_due_subscriptions(by_provider) do
    ProviderConfig.subscription_provider_strings()
    |> Enum.flat_map(&Map.get(by_provider, &1, []))
    |> Enum.filter(&subscription_due?/1)
    |> enqueue_batched(SyncIcsCalendarWorker)
  end

  defp subscription_due?(%{last_external_sync_at: nil}), do: true

  defp subscription_due?(integration) do
    cutoff = DateTime.add(DateTime.utc_now(), -@subscription_interval, :second)
    DateTime.before?(integration.last_external_sync_at, cutoff)
  end

  # ---------------------------------------------------------------------------
  # Exchange scheduling
  # ---------------------------------------------------------------------------

  defp enqueue_due_exchange(by_provider) do
    ProviderConfig.ews_provider_strings()
    |> Enum.flat_map(&Map.get(by_provider, &1, []))
    |> Enum.filter(&exchange_due?/1)
    |> enqueue_batched(SyncExchangeCalendarWorker)
  end

  defp exchange_due?(%{last_external_sync_at: nil}), do: true

  defp exchange_due?(integration) do
    cutoff = DateTime.add(DateTime.utc_now(), -@exchange_interval, :second)
    DateTime.before?(integration.last_external_sync_at, cutoff)
  end

  # ---------------------------------------------------------------------------
  # CalDAV tier-aware scheduling
  # ---------------------------------------------------------------------------

  defp caldav_due?(%{last_external_sync_at: nil}), do: true

  defp caldav_due?(integration) do
    interval =
      Map.get(@caldav_tier_intervals, integration.caldav_sync_tier, @caldav_default_interval)

    cutoff = DateTime.add(DateTime.utc_now(), -interval, :second)
    DateTime.before?(integration.last_external_sync_at, cutoff)
  end

  # ---------------------------------------------------------------------------
  # Periodic forced full fetch (recovers events missed by Tier 1/2 optimisations)
  # ---------------------------------------------------------------------------

  defp enqueue_caldav_forced_full_fetches(integrations) do
    now = DateTime.utc_now()
    due = Enum.filter(integrations, &forced_full_fetch_due?(&1, now))

    process_in_batches(due, fn integration, _batch_index ->
      delay_seconds = :rand.uniform(@forced_full_fetch_jitter_seconds)
      scheduled_at = DateTime.add(now, delay_seconds, :second)

      args = %{
        "calendar_integration_id" => integration.id,
        "force_full_fetch" => true
      }

      case Oban.insert(SyncCalDavCalendarWorker.new(args, scheduled_at: scheduled_at)) do
        {:ok, %Oban.Job{conflict?: true}} ->
          :conflict

        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to enqueue forced full-fetch CalDAV job",
            calendar_integration_id: integration.id,
            error: reason
          )

          :error
      end
    end)
  end

  defp forced_full_fetch_due?(%{last_full_sync_at: nil}, _now), do: true

  defp forced_full_fetch_due?(%{last_full_sync_at: last_full_sync_at}, now) do
    cutoff = DateTime.add(now, -@forced_full_fetch_interval_seconds, :second)
    DateTime.before?(last_full_sync_at, cutoff)
  end
end
