defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventQueueQueries do
  @moduledoc """
  The offline write queue's half of the cached-event table.

  CalDAV is the only provider family that writes locally before the server has
  agreed. When such a write fails — the server unreachable, a 412 on a stale
  etag — the intent must survive until it can be replayed, so the cache row is
  tagged with `sync_state`, `sync_attempts`, `sync_last_attempt_at` and
  `sync_last_error`, and `CalDAV.OfflineQueue` replays it at the start of the
  next sync cycle.

  Those four columns are the reason this is a separate module rather than more
  functions in `ProviderCalendarEventQueries`. That module answers "what does
  the provider say is on this calendar?" and its `upsert_batch/1` deliberately
  *protects* these columns, so a fresh server-view sync cannot clobber a pending
  local change. This module answers the opposite question — "what have we not
  yet managed to tell the provider?" — and every function here writes exactly
  the columns the other one refuses to. Keeping them apart makes that opposition
  visible instead of leaving two upserts with subtly different conflict lists
  side by side.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @doc """
  Upserts a row to tag it for the offline write queue.

  Unlike `upsert_batch/1`, this helper also updates the queue-tracking
  columns (`sync_state`, `sync_attempts`, `sync_last_attempt_at`,
  `sync_last_error`) on conflict. Used exclusively by
  `CalDAV.QueueWiring.tag/3` when a local write has failed and needs
  to be replayed later — the caller's latest intent must take effect.

  Regular server-sourced upserts go through `upsert_batch/1`, which
  deliberately protects the queue-tracking columns to avoid clobbering
  pending local changes with a fresh server-view sync.

  Returns `{:ok, 1}` on success.
  """
  @spec upsert_queue_entry(map()) :: {:ok, 1}
  def upsert_queue_entry(attrs) when is_map(attrs) do
    now = DateTime.utc_now(:microsecond)

    entry =
      attrs
      |> Map.put_new(:inserted_at, now)
      |> Map.put(:updated_at, now)

    {1, _rows} =
      Repo.insert_all(
        ProviderCalendarEventSchema,
        [entry],
        on_conflict: {:replace, queue_entry_replace_fields()},
        conflict_target: [:calendar_integration_id, :uid]
      )

    {:ok, 1}
  end

  @doc """
  Lists cache rows with a pending local change for the given integration.

  Used by `OfflineQueue.flush/2` at the start of each sync cycle to
  replay local creates / updates / deletes against the remote server
  before pulling remote changes.

  Returned in ascending `updated_at` order so the oldest pending change
  is replayed first — preserves FIFO semantics across edits to the same
  cached row.
  """
  @spec list_pending(integer()) :: [ProviderCalendarEventSchema.t()]
  def list_pending(calendar_integration_id) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.sync_state != "synced")
    |> order_by([e], asc: e.updated_at)
    |> Repo.all()
  end

  @doc """
  Marks a cache row as successfully replayed to the server.

  Clears `sync_state`, resets `sync_attempts`, records the attempt time,
  and optionally updates the persisted `etag` with the value the server
  returned on the successful write.

  Returns `{:ok, :updated}` if the row existed; `{:ok, :not_found}`
  if no row matched (the row was deleted between `list_pending/1`
  and `mark_synced/3`, which is benign).
  """
  @spec mark_synced(integer(), String.t(), String.t() | nil) ::
          {:ok, :updated | :not_found}
  def mark_synced(calendar_integration_id, uid, new_etag) do
    now = DateTime.utc_now(:microsecond)

    set =
      maybe_put_etag(
        [
          sync_state: "synced",
          sync_attempts: 0,
          sync_last_attempt_at: now,
          sync_last_error: nil,
          updated_at: now
        ],
        new_etag
      )

    {count, _rows} =
      ProviderCalendarEventSchema
      |> where(
        [e],
        e.calendar_integration_id == ^calendar_integration_id and e.uid == ^uid
      )
      |> Repo.update_all(set: set)

    if count > 0, do: {:ok, :updated}, else: {:ok, :not_found}
  end

  @doc """
  Records a failed replay attempt for a pending cache row.

  Increments `sync_attempts`, stamps `sync_last_attempt_at`, and stores
  the formatted error in `sync_last_error`. Does not change
  `sync_state` — the row stays in the queue and will be retried on
  the next sync cycle.
  """
  @spec mark_sync_failed(integer(), String.t(), String.t()) :: :ok
  def mark_sync_failed(calendar_integration_id, uid, reason) when is_binary(reason) do
    now = DateTime.utc_now(:microsecond)

    ProviderCalendarEventSchema
    |> where(
      [e],
      e.calendar_integration_id == ^calendar_integration_id and e.uid == ^uid
    )
    |> Repo.update_all(
      inc: [sync_attempts: 1],
      set: [sync_last_attempt_at: now, sync_last_error: reason]
    )

    :ok
  end

  defp maybe_put_etag(set, nil), do: set
  defp maybe_put_etag(set, etag) when is_binary(etag), do: Keyword.put(set, :etag, etag)

  # Queue-entry upserts update the same content columns as replace_fields/0
  # PLUS the sync_state bookkeeping columns, because the caller
  # (CalDAV.QueueWiring) is declaring a new local intent and the latest
  # tag must win over any stale queue marker.
  defp queue_entry_replace_fields do
    ProviderCalendarEventQueries.replace_fields() ++
      [:sync_state, :sync_attempts, :sync_last_attempt_at, :sync_last_error, :created_by_tymeslot]
  end
end
