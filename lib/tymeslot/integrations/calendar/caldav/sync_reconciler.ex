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

  @doc """
  Detects events that have been deleted from the server by comparing
  fetched UIDs against the local cache.

  Used after a full fetch (Tier 2 CTag change or Tier 3) to find events
  present in the cache but absent from the server response within the
  sync time window.
  """
  @spec detect_deletions(map(), list(map()), DateTime.t(), DateTime.t(), DateTime.t(), String.t()) ::
          :ok
  def detect_deletions(
        integration,
        fetched_events,
        start_time,
        end_time,
        sync_started_at,
        calendar_path
      ) do
    fetched_uids = MapSet.new(fetched_events, &Map.get(&1, :uid))

    cached_uids =
      ProviderCalendarEventQueries.list_uids_in_range(
        integration.id,
        start_time,
        end_time,
        sync_started_at,
        calendar_path
      )

    missing_uids = Enum.reject(cached_uids, &MapSet.member?(fetched_uids, &1))

    if missing_uids != [] do
      Logger.info("CalDAV full fetch detected missing events",
        calendar_integration_id: integration.id,
        missing_count: length(missing_uids)
      )

      Enum.each(missing_uids, fn uid ->
        ProviderCalendarEventQueries.delete_by_uid(integration.id, uid)

        case Sync.reconcile(integration.id, nil, uid, :deleted) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Reconcile failed for deleted event",
              uid: uid,
              integration_id: integration.id,
              reason: inspect(reason)
            )
        end
      end)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalisation_context(integration) do
    %{
      calendar_integration_id: integration.id,
      provider_calendar_id: List.first(integration.calendar_paths),
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
            Enum.each(deleted_hrefs, fn href ->
              ProviderCalendarEventQueries.delete_by_provider_event_id(integration.id, href)
            end)

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

    if missing_uids != [] do
      Logger.info("CalDAV full fetch detected missing events",
        calendar_integration_id: integration.id,
        missing_count: length(missing_uids)
      )

      Enum.each(missing_uids, fn uid ->
        ProviderCalendarEventQueries.delete_by_uid(integration.id, uid)
      end)
    end

    missing_uids
  end

  # Post-commit side effects for full-fetch deletions.
  defp reconcile_missing_uids(_integration, []), do: :ok

  defp reconcile_missing_uids(integration, missing_uids) do
    Enum.each(missing_uids, fn uid ->
      case Sync.reconcile(integration.id, nil, uid, :deleted) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Reconcile failed for deleted event",
            uid: uid,
            integration_id: integration.id,
            reason: inspect(reason)
          )
      end
    end)
  end

  # Post-commit side effects for Tier 1 href-based deletions.
  defp reconcile_deleted_hrefs(_integration, []), do: :ok

  defp reconcile_deleted_hrefs(integration, hrefs) do
    Enum.each(hrefs, fn href ->
      case Sync.reconcile(integration.id, href, nil, :deleted) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Reconcile failed for deleted event",
            href: href,
            integration_id: integration.id,
            reason: inspect(reason)
          )
      end
    end)
  end

  defp process_href_deletions(_integration, []), do: :ok

  defp process_href_deletions(integration, deleted_hrefs) do
    Enum.each(deleted_hrefs, fn href ->
      ProviderCalendarEventQueries.delete_by_provider_event_id(integration.id, href)

      case Sync.reconcile(integration.id, href, nil, :deleted) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Reconcile failed for deleted event",
            href: href,
            integration_id: integration.id,
            reason: inspect(reason)
          )
      end
    end)
  end
end
