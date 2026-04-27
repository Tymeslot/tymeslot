defmodule Tymeslot.Workers.FallbackSyncSweepWorker do
  @moduledoc """
  Oban worker that performs a sweep of all active calendar integrations every
  15 minutes as a fallback mechanism for missed or delayed webhook notifications.

  For each provider the sweep takes the cheapest available action:

  - **Google** — enqueues a `SyncGoogleCalendarWorker` job per integration.
  - **Outlook (with delta link)** — delegates to `Outlook.DeltaSync.fetch_and_apply/1`,
    which fetches the delta directly from the stored `graph_delta_link` URL,
    upserts changed events into the cache, and stores the new delta link.
    This avoids a full re-sync while keeping the integration current without
    relying on webhook delivery.
  - **Outlook (no delta link)** — re-registers the Graph subscription (which also
    seeds an initial delta snapshot) so future sweeps can use the delta path.
  - **CalDAV / Radicale / Nextcloud / Zimbra** — enqueues a `SyncCalDavCalendarWorker`
    job at a frequency determined by the integration's sync tier:
    - Tier 1 (sync-token delta): every 15 minutes
    - Tier 2 (CTag check): every 30 minutes
    - Tier 3 (full fetch): every hour
    - Undetected (nil): every 15 minutes (detect tier ASAP)

  Integrations are processed in batches of 50 with a 1-second pause between
  batches to avoid thundering-herd load on provider APIs and the database.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1,
    unique: [period: 900]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync, as: OutlookDeltaSync
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.HealthCheck.SyncGating
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  @batch_size 50
  @batch_sleep_ms 1_000

  # Sync interval per CalDAV tier (in seconds).
  # Tier 1 and 2 are lightweight; Tier 3 does a full fetch every time.
  @caldav_tier_intervals %{
    1 => 900,
    2 => 1_800,
    3 => 3_600
  }
  @caldav_default_interval 900

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

    {outlook_delta_count, outlook_enqueued_count} =
      process_outlook(Map.get(by_provider, "outlook", []))

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

    Logger.info("FallbackSyncSweep complete",
      google_scheduled: google_count,
      outlook_delta_fetched: outlook_delta_count,
      outlook_enqueued: outlook_enqueued_count,
      caldav_scheduled: caldav_count,
      caldav_skipped: caldav_skipped,
      caldav_forced_full_scheduled: forced_full_count,
      caldav_forced_full_conflicts: forced_full_conflicts
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
      if batch_index > 0, do: Process.sleep(@batch_sleep_ms)

      {batch_count, batch_conflicts} =
        Enum.reduce(batch, {0, 0}, fn item, {count, confl} ->
          case per_item_fun.(item) do
            :ok -> {count + 1, confl}
            :conflict -> {count, confl + 1}
            :error -> {count, confl}
          end
        end)

      {total + batch_count, conflicts + batch_conflicts}
    end)
  end

  defp enqueue_batched(integrations, worker_module) do
    {scheduled, _conflicts} =
      process_in_batches(integrations, fn integration ->
        args = %{"calendar_integration_id" => integration.id}

        case Oban.insert(worker_module.new(args)) do
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

    process_in_batches(due, fn integration ->
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

  # ---------------------------------------------------------------------------
  # Outlook
  # ---------------------------------------------------------------------------

  defp process_outlook(integrations) do
    {with_delta, without_delta} =
      Enum.split_with(integrations, fn i -> not is_nil(i.graph_delta_link) end)

    {delta_count, _delta_errors} =
      process_in_batches(with_delta, &OutlookDeltaSync.fetch_and_apply/1)

    {enqueued_count, _enqueued_errors} =
      process_in_batches(without_delta, &seed_outlook_integration/1)

    {delta_count, enqueued_count}
  end

  defp outlook_calendar_api do
    Application.get_env(:tymeslot, :outlook_calendar_api_module, OutlookCalendarAPI)
  end

  # Seed path runs whenever an Outlook integration has no `graph_delta_link`.
  # Uses `bootstrap_sync` so the delta baseline + cache land on every
  # deployment — webhook subscription is a separate, opportunistic step that
  # only fires when `webhook_base_url` is configured.
  defp seed_outlook_integration(integration) do
    case outlook_calendar_api().bootstrap_sync(integration) do
      {:ok, updated} ->
        maybe_register_subscription(updated)
        :ok

      error ->
        Logger.warning(
          "Outlook bootstrap delta fetch failed in fallback sweep",
          calendar_integration_id: integration.id,
          error: format_error(error)
        )

        :error
    end
  end

  defp maybe_register_subscription(integration) do
    case outlook_calendar_api().register_graph_subscription(integration) do
      {:ok, _updated} ->
        :ok

      {:error, :webhook_base_url_not_configured} ->
        Logger.debug(
          "Webhook base URL not configured; skipping Outlook subscription registration",
          calendar_integration_id: integration.id
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to register Outlook Graph subscription after bootstrap",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        :ok
    end
  end

  defp format_error({:error, type, reason}) when is_atom(type),
    do: "#{type}: #{inspect(reason)}"

  defp format_error({:error, reason}), do: inspect(reason)

  defp format_error(other), do: inspect(other)
end
