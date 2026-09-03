defmodule Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler do
  @moduledoc """
  Deletion reconciliation and event processing for CalDAV sync workers.

  Handles three concerns that sit between raw CalDAV protocol operations and
  the provider-agnostic `Sync` module:

  1. **Safe event processing** — normalises raw CalDAV events, persists them
     via `Sync.persist_normalised_events/2`, and processes any deletion hrefs
     from a Tier 1 sync-collection response.

  2. **Href-based deletions** (Tier 1) — processes explicit deletion signals
     from sync-collection responses where the server reports removed resources
     by href.

  3. **UID-based deletion detection** (Tier 2/3 full fetch) — compares
     fetched event UIDs against the local cache to identify events that have
     disappeared from the server within the sync time window.

  ## Atomicity

  `process_full_fetch/6` and `process_tier1/3` wrap the cache-level writes
  (upsert + delete) in a single `Repo.transaction`. A crash, exception, or
  error return mid-way rolls the whole batch back, so the cache can never
  observe a partial sync.

  Meeting-level reconciliation (`Sync.reconcile/4`) and PubSub broadcasts
  run **outside** the transaction, because they have observable side
  effects (emails, cancellation workflows) that must not be rolled back.
  The transaction returns the list of actions to run post-commit; those
  actions are then executed best-effort.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Repo

  @doc """
  Atomically reconciles a Tier 2/3 full-fetch response.

  Wraps cache upsert AND deletion detection in a single `Repo.transaction`:

  1. Normalises raw events
  2. Upserts the batch (inside tx)
  3. Reads cached UIDs in the sync window (inside tx)
  4. Deletes cache rows for UIDs missing from the server response (inside tx)
  5. Commits
  6. Post-commit: broadcasts, runs meeting-time-change reconciliation,
     runs deletion reconciliation (may send emails; must not roll back)

  Returns `:ok` on success. On `{:error, reason}` the transaction has
  already rolled back — the cache is untouched and no side effects fire.
  """
  @spec process_full_fetch(
          map(),
          list(map()),
          DateTime.t(),
          DateTime.t(),
          DateTime.t(),
          String.t()
        ) :: :ok | {:error, term()}
  def process_full_fetch(
        integration,
        events,
        start_time,
        end_time,
        sync_started_at,
        calendar_path
      ) do
    context = normalisation_context(integration)

    with {:ok, calendar_events} <- CalDAVProvider.normalise_events(events, context) do
      run_atomic_full_fetch(
        integration,
        calendar_events,
        start_time,
        end_time,
        sync_started_at,
        calendar_path
      )
    end
  end

  @doc """
  Atomically reconciles a Tier 1 sync-collection response.

  Wraps cache upsert AND href-based cache deletion in a single
  `Repo.transaction`. Returns `:ok` or `{:error, reason}`. See
  `process_full_fetch/6` for the post-commit contract.
  """
  @spec process_tier1(map(), list(map()), list(String.t())) :: :ok | {:error, term()}
  def process_tier1(integration, events, deleted_hrefs) do
    context = normalisation_context(integration)

    with {:ok, calendar_events} <- CalDAVProvider.normalise_events(events, context) do
      run_atomic_tier1(integration, calendar_events, deleted_hrefs)
    end
  end

  @doc """
  Normalises, persists, and reconciles a batch of CalDAV events.

  Optionally processes a list of `deleted_hrefs` from a Tier 1
  sync-collection response. Returns `:ok` on success or
  `{:error, reason}` if normalisation or persistence fails.

  **Non-atomic.** Prefer `process_full_fetch/6` or `process_tier1/3`
  for sync paths where partial-failure consistency matters.
  """
  @spec safe_process_events(map(), list(map()), list(String.t())) :: :ok | {:error, term()}
  def safe_process_events(integration, events, deleted_hrefs \\ []) do
    context = normalisation_context(integration)

    with {:ok, calendar_events} <- CalDAVProvider.normalise_events(events, context),
         :ok <- Sync.persist_normalised_events(integration, calendar_events) do
      process_href_deletions(integration, deleted_hrefs)
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Deletion circuit breaker
  # ---------------------------------------------------------------------------

  # A full-fetch listing implies deletions by *absence*: any cached UID the
  # server no longer returns is treated as deleted, which feeds
  # `apply_external_calendar_change(:deleted)` — auto-cancelling the linked
  # meeting and emailing both parties. That inference is only sound when the
  # listing is authoritative. A syntactically valid but empty response, or a
  # batch where every event failed to parse and was silently dropped, both
  # arrive here as "the server returned (almost) nothing" and would classify
  # the entire cache as stale — the one non-self-healing damage path in the
  # sync stack.
  #
  # A deletion batch looks suspicious when either the remote set is empty while
  # the cache is not (the strongest failed-read signal, applied at any cache
  # size), or a non-trivial cache would lose more than
  # `@bulk_delete_ratio_threshold` of its rows in a single sync.
  #
  # Suspicion alone cannot refuse forever, though. A failed read and a calendar
  # the user genuinely emptied produce the *same* listing, so "wait for a later
  # healthy fetch" never resolves the second case: the refusal blocks the sync
  # token, the next cycle re-fetches the same empty listing, and the integration
  # deadlocks. What separates the two is persistence over time — a transient
  # read failure does not survive dozens of cycles. `synced_at` on the cached
  # row is frozen at the last fetch that returned the event, so it already
  # measures exactly that, with no extra state to store.
  #
  # So: refuse a suspicious batch only while its rows are still recent. Once
  # every missing row has gone unconfirmed for `@bulk_delete_grace_hours`, the
  # absence is treated as real and the deletions are reconciled. Ordinary small
  # deletions stay below the threshold and are never delayed.
  @bulk_delete_ratio_threshold 0.8
  @bulk_delete_min_cache 5
  @bulk_delete_grace_hours 24

  # Classifies a deletion batch. `:proceed_after_grace` is `:proceed` that the
  # circuit breaker held back until the absence was corroborated over time; it
  # is distinguished only so the release can be logged.
  @spec deletion_verdict(map(), [String.t()], [String.t()], MapSet.t(), DateTime.t()) ::
          :nothing_to_delete | :proceed | :proceed_after_grace | :refuse
  defp deletion_verdict(integration, cached_uids, missing_uids, fetched_uids, sync_started_at) do
    cond do
      missing_uids == [] -> :nothing_to_delete
      not suspicious_deletion?(cached_uids, missing_uids, fetched_uids) -> :proceed
      absent_beyond_grace?(integration, missing_uids, sync_started_at) -> :proceed_after_grace
      true -> :refuse
    end
  end

  defp suspicious_deletion?(cached_uids, missing_uids, fetched_uids) do
    cached_count = length(cached_uids)

    remote_empty_but_cache_populated?(cached_count, MapSet.size(fetched_uids)) or
      over_delete_ratio?(cached_count, length(missing_uids))
  end

  defp remote_empty_but_cache_populated?(cached_count, 0) when cached_count > 0, do: true
  defp remote_empty_but_cache_populated?(_cached_count, _fetched_count), do: false

  defp over_delete_ratio?(cached_count, missing_count)
       when cached_count >= @bulk_delete_min_cache,
       do: missing_count / cached_count >= @bulk_delete_ratio_threshold

  defp over_delete_ratio?(_cached_count, _missing_count), do: false

  # True once *every* missing row has gone unconfirmed for longer than the grace
  # period; the newest of them decides. Measured against `sync_started_at`, the
  # same reference `list_uids_in_range/5` uses to pick these rows, so the whole
  # comparison runs off one clock.
  defp absent_beyond_grace?(integration, missing_uids, sync_started_at) do
    cutoff = DateTime.add(sync_started_at, -@bulk_delete_grace_hours, :hour)

    case ProviderCalendarEventQueries.max_synced_at_for_uids(integration.id, missing_uids) do
      nil -> false
      last_confirmed_at -> DateTime.before?(last_confirmed_at, cutoff)
    end
  end

  # Logged at :warning, not :error — the refusal is expected, self-resolving,
  # and needs no operator action, so it must not read as a page.
  defp log_suspicious_deletion(integration, cached_uids, missing_uids, calendar_path) do
    Logger.warning(
      "CalDAV full fetch would delete a suspicious share of the cache; refusing to reconcile deletions",
      calendar_integration_id: integration.id,
      calendar_path: calendar_path,
      cached_count: length(cached_uids),
      missing_count: length(missing_uids),
      grace_hours: @bulk_delete_grace_hours
    )
  end

  # A release is worth an operator-visible line at :warning: real cancellations
  # and participant emails follow from it, after a batch that looked suspicious.
  # An ordinary deletion is routine and stays at :info.
  defp log_deletions_proceeding(:proceed_after_grace, integration, missing_uids, calendar_path) do
    Logger.warning(
      "CalDAV deletion circuit breaker released after grace period; reconciling deletions",
      calendar_integration_id: integration.id,
      calendar_path: calendar_path,
      missing_count: length(missing_uids),
      grace_hours: @bulk_delete_grace_hours
    )
  end

  defp log_deletions_proceeding(:proceed, integration, missing_uids, _calendar_path) do
    Logger.info("CalDAV full fetch detected missing events",
      calendar_integration_id: integration.id,
      missing_count: length(missing_uids)
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalisation_context(integration) do
    calendar_paths = integration.calendar_paths || []

    %{
      calendar_integration_id: integration.id,
      # Only the fallback for an event whose href matches no known collection.
      # The normaliser files each event under the path its own href is rooted
      # at, so a batch spanning several calendars is filed per calendar rather
      # than all under the first one.
      provider_calendar_id: List.first(calendar_paths),
      calendar_paths: calendar_paths,
      synced_at: DateTime.utc_now(:microsecond)
    }
  end

  # Runs the cache upsert + deletion detection + cache delete under a single
  # transaction and returns {calendar_events, deleted_uids}. On post-commit,
  # runs side-effect reconciliation with the returned tuple.
  defp run_atomic_full_fetch(
         integration,
         calendar_events,
         start_time,
         end_time,
         sync_started_at,
         calendar_path
       ) do
    txn_result =
      Repo.transaction(fn ->
        case Sync.upsert_cache(integration, calendar_events) do
          {:ok, _count} ->
            compute_and_delete_missing_uids(
              integration,
              calendar_events,
              start_time,
              end_time,
              sync_started_at,
              calendar_path
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case txn_result do
      {:ok, deleted_uids} ->
        Sync.post_commit_reconciliation(integration, calendar_events)

        # post_commit_reconciliation is a no-op when calendar_events is empty.
        # Ensure the cache is invalidated even when the sync only deleted events.
        if calendar_events == [] and deleted_uids != [] do
          Sync.invalidate_cache_for_user(integration)
        end

        reconcile_missing_uids(integration, deleted_uids)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_atomic_tier1(integration, calendar_events, deleted_hrefs) do
    txn_result =
      Repo.transaction(fn ->
        case Sync.upsert_cache(integration, calendar_events) do
          {:ok, _count} ->
            ProviderCalendarEventQueries.delete_by_provider_event_ids(
              integration.id,
              deleted_hrefs
            )

            deleted_hrefs

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case txn_result do
      {:ok, hrefs} ->
        Sync.post_commit_reconciliation(integration, calendar_events)

        # post_commit_reconciliation is a no-op when calendar_events is empty.
        # Ensure the cache is invalidated even when the sync only deleted events.
        if calendar_events == [] and hrefs != [] do
          Sync.invalidate_cache_for_user(integration)
        end

        reconcile_deleted_hrefs(integration, hrefs)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Inside the transaction: compute UIDs missing from the server response
  # and delete the corresponding cache rows. Returns the list of deleted
  # UIDs so the caller can reconcile them after commit.
  defp compute_and_delete_missing_uids(
         integration,
         calendar_events,
         start_time,
         end_time,
         sync_started_at,
         calendar_path
       ) do
    fetched_uids = MapSet.new(calendar_events, fn %CalendarEvent{uid: uid} -> uid end)

    cached_uids =
      ProviderCalendarEventQueries.list_uids_in_range(
        integration.id,
        start_time,
        end_time,
        sync_started_at,
        calendar_path
      )

    missing_uids = Enum.reject(cached_uids, &MapSet.member?(fetched_uids, &1))

    case deletion_verdict(integration, cached_uids, missing_uids, fetched_uids, sync_started_at) do
      :nothing_to_delete ->
        []

      :refuse ->
        # Roll the whole batch back: the cache is left untouched and the sync
        # token is not advanced, so the next cycle re-evaluates against a fresh
        # fetch. The worker discards rather than retrying — a retry within this
        # cycle would refuse identically.
        log_suspicious_deletion(integration, cached_uids, missing_uids, calendar_path)
        Repo.rollback(:suspicious_bulk_deletion)

      verdict ->
        log_deletions_proceeding(verdict, integration, missing_uids, calendar_path)
        ProviderCalendarEventQueries.delete_by_uids(integration.id, missing_uids)
        missing_uids
    end
  end

  # Post-commit side effects for full-fetch deletions. The cache rows were
  # already deleted inside the transaction.
  defp reconcile_missing_uids(integration, missing_uids) do
    Sync.reconcile_deletions(integration, uid_refs(missing_uids), delete_cache: false)
  end

  # Post-commit side effects for Tier 1 href-based deletions. The cache rows
  # were already deleted inside the transaction.
  defp reconcile_deleted_hrefs(integration, hrefs) do
    Sync.reconcile_deletions(integration, href_refs(hrefs), delete_cache: false)
  end

  defp process_href_deletions(integration, deleted_hrefs) do
    Sync.reconcile_deletions(integration, href_refs(deleted_hrefs))
  end

  defp uid_refs(uids), do: Enum.map(uids, &%{provider_event_id: nil, uid: &1})

  defp href_refs(hrefs), do: Enum.map(hrefs, &%{provider_event_id: &1, uid: nil})
end
