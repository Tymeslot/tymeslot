defmodule Tymeslot.Integrations.Calendar.SyncLink.WriteBack do
  @moduledoc """
  Enqueues the mirror write that follows a source event changing.

  Split out of the sync path for the same reason `ColourWriteBack` is split out
  of the calendar context: this is the enqueue mechanism, not a domain entry
  point, and keeping it here means the sync path holds one call rather than
  Oban's vocabulary.

  ## Why this always returns `:ok`

  The caller is `Sync.post_commit_reconciliation/2`, which runs after an inbound
  sync has already committed. Surfacing an enqueue failure there would give the
  sync worker an error for work that succeeded, and there is nothing useful for
  it to do about it: the cache is correct, the mirror is merely late, and the
  reconcile sweep finds a source with no matching mirror and writes it. A
  mirror write is best-effort by design — a target calendar that is slow, down,
  or over quota must never be able to fail an inbound sync of a different
  calendar.

  So a failed enqueue is logged and swallowed. What is not acceptable is a
  failure that leaves no trace, which is the reason for the log line rather
  than a bare `:ok`.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBackQueries
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  @typedoc """
  `:upsert` covers both create and update — which one it is depends on whether a
  mapping row exists at the time the job runs, which the enqueue site cannot
  know and should not guess. `:delete` withdraws a placeholder whose source is
  gone.
  """
  @type operation :: :upsert | :delete

  @doc """
  Enqueues one mirror write.

  Replacing the args matters here for the same reason it does on the colour
  write-back, and one case more. `unique` alone keeps the *first* pending job
  and drops the newer enqueue, so an event edited twice before the queue drains
  would mirror the first edit and silently discard the second. Worse, an event
  edited and then deleted would keep the upsert and drop the delete, leaving a
  placeholder on the target for an event that no longer exists. Replacing the
  args means the pending job always carries the latest intent.

  The replace is named per state rather than given bare, and the omission is the
  point. A bare `replace: [:args]` expands across *every* state Oban knows —
  `Oban.Job.put_replace/3` maps the fields over `states()` — including
  `:executing`. A job already running has read its args; rewriting the row
  changes nothing it will do, so the newer intent is not deferred but lost. A
  delete arriving while the upsert runs would vanish into it, the placeholder
  would be written for an event that no longer exists, and no pending job would
  remain to correct it. Naming only the states where a job has not yet started
  leaves the delete to be inserted as its own job, which runs once the upsert
  finishes.
  """
  @spec enqueue(integer(), String.t(), operation(), keyword()) :: :ok
  def enqueue(sync_link_id, source_uid, operation, opts \\ [])

  def enqueue(sync_link_id, source_uid, operation, opts)
      when is_integer(sync_link_id) and is_binary(source_uid) and operation in [:upsert, :delete] and
             is_list(opts) do
    %{
      "sync_link_id" => sync_link_id,
      "source_uid" => source_uid,
      "operation" => Atom.to_string(operation)
    }
    |> put_moves(sync_link_id, source_uid, Keyword.get(opts, :moved))
    |> SyncLinkWriteBackWorker.new(
      replace: [
        available: [:args],
        scheduled: [:args],
        retryable: [:args]
      ]
    )
    |> Oban.insert()
    |> log_enqueue_error(sync_link_id, source_uid)

    :ok
  end

  # Moved occurrences travel on the job because they cannot be read at write
  # time: the cache keeps one row per series and the moved instance is collapsed
  # into it before the worker runs. See `SyncLink.MoveCorrection`.
  #
  # The `replace` above swaps args wholesale, so a plain enqueue arriving after
  # one carrying moves would drop them — and an ordinary sync enqueues for every
  # event it sees, which makes that the common ordering rather than a rare one.
  # A correction lost that way is not deferred, it is gone until the next sync
  # that sees the move re-detects it.
  #
  # Preserving is therefore opt-in rather than automatic. `enqueue/3` runs once
  # per event per link on every sync, and a lookup there would be a query per
  # synced event on every calendar — the cost the sync path avoids by fetching
  # the mirror set once for the whole batch. Only a caller re-enqueueing a
  # series it already knows about pays it, by passing `moved: :preserve`:
  # `SyncLinkReconcileWorker`, whose whole job is to repair writes the push path
  # missed, and `Remirror`, which rewrites every placeholder a link holds after
  # a presentation change. Both would otherwise destroy a correction while
  # repairing the thing it was correcting.
  #
  # Fresh moves always win over preserved ones: a newer detection is the current
  # truth, and merging the two sets would keep correcting a move the organiser
  # has since undone.
  defp put_moves(args, _sync_link_id, _source_uid, moved) when is_list(moved) and moved != [],
    do: Map.put(args, "moved", moved)

  defp put_moves(args, sync_link_id, source_uid, :preserve) do
    case WriteBackQueries.pending_moves(sync_link_id, source_uid) do
      nil -> args
      moved -> Map.put(args, "moved", moved)
    end
  end

  defp put_moves(args, _sync_link_id, _source_uid, _none), do: args

  defp log_enqueue_error({:ok, _job}, _sync_link_id, _source_uid), do: :ok

  defp log_enqueue_error({:error, reason}, sync_link_id, source_uid) do
    Logger.warning("Failed to enqueue calendar sync-link write-back",
      sync_link_id: sync_link_id,
      source_uid: source_uid,
      reason: inspect(reason)
    )

    :ok
  end
end
