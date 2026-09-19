defmodule Tymeslot.Integrations.Calendar.CalDAV.QueueQueries do
  @moduledoc """
  Persistence for the CalDAV offline write queue.

  A cache row carries the ordinary provider columns *and* a small set of
  bookkeeping columns (`sync_state`, `sync_attempts`, `sync_last_attempt_at`,
  `sync_last_error`) recording a local change that has not yet reached the
  server. Those columns have their own lifecycle: they are written when
  Tymeslot declares a local intent, read back by `OfflineQueue.flush/2` at the
  start of each sync cycle, and cleared when the replay succeeds. That is a
  different concern from caching what a provider returned, and it is used by
  `CalDAV.OfflineQueue` and `CalDAV.QueueWiring` alone, so it lives here rather
  than in `ProviderCalendarEventQueries`.

  Both modules write the same table, but not the same way. A server-sourced
  sync replaces the fixed set of content columns
  `ProviderCalendarEventQueries.replace_fields/0` names, because it has just
  read the whole event. A queue tag has not: it knows only the fields the local
  change carried, so it replaces exactly those and leaves the rest of the row
  alone. See `upsert_queue_entry/1`.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  # Columns that identify the row rather than describe it, and so are written
  # once at insert and never replaced. `:uid` and `:calendar_integration_id`
  # are the conflict target. `:provider` and `:provider_calendar_id` are
  # insert-time identity for the reason `ProviderCalendarEventQueries`
  # withholds them: a queue tag only knows the integration's first configured
  # path, which is not the collection an event on any other calendar lives in.
  @identity_fields [
    :uid,
    :calendar_integration_id,
    :provider,
    :provider_calendar_id,
    :inserted_at
  ]

  @doc """
  Upserts a row to tag it for the offline write queue.

  **Replaces exactly the columns `attrs` carries.** `{:replace, …}` on an
  upsert replaces with `EXCLUDED`, which for a column the insert omits is
  NULL — so a replace list naming more columns than the write supplies is a
  list of columns the write silently blanks. That is what used to happen here:
  the list was `ProviderCalendarEventQueries.replace_fields/0` plus the
  bookkeeping columns, while `CalDAV.QueueWiring.build_attrs/4` supplied a
  third of it, so tagging an event for retry nulled its `etag`,
  `provider_event_id`, `raw_ical`, `attendees`, `reminders` and RRULE. A
  queued delete, which carries no event data at all, destroyed the identity of
  the very row it was about to retry the delete for.

  Deriving the list from the attrs instead makes that shape impossible: a
  field the caller did not supply is not in the list, so the existing value
  stands. `CalDAV.QueueWiring` is the only caller, and it supplies a field
  only when the local change actually carried one.

  Regular server-sourced upserts go through
  `ProviderCalendarEventQueries.upsert_batch/1`, which deliberately protects
  the queue-tracking columns to avoid clobbering pending local changes with a
  fresh server-view sync.

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
        on_conflict: {:replace, replace_fields_for(entry)},
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

  defp replace_fields_for(entry) do
    entry |> Map.keys() |> Enum.reject(&(&1 in @identity_fields))
  end
end
