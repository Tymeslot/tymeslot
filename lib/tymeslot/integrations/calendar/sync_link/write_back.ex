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

  # Long enough that the job which caused the conflict has finished a provider
  # round trip, short enough that a withdrawal is not visibly late. A mirror
  # write is one create-or-update against Google or Outlook; the seconds-long
  # tail belongs to the retry ladder, and a follow-up landing while the first
  # job is still going merely conflicts again and defers again, which is the
  # safe direction.
  @defer_seconds 30

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
  leaves the running job alone.

  ## Why the executing conflict needs its own insert

  Leaving the running job alone is necessary and is not sufficient, and the
  gap between those two was measured rather than reasoned about.

  The worker's uniqueness window includes `:executing`, so an enqueue arriving
  while a job runs *matches that job* as the conflict. Oban 2.23's
  `Basic.resolve_conflict/4` then looks the job's state up in the `replace`
  keyword — `Keyword.get(replace, :executing, [])` — finds nothing named, takes
  no fields, and returns the existing row with `conflict?: true`. **Nothing is
  inserted.** The newer intent is not deferred to a second job; it is dropped
  on the floor, which is the opposite of what this moduledoc claimed before the
  behaviour was put under test.

  Two live consequences, both reproduced end to end through the ordinary sync
  path in `WriteBackExecutingConflictTest`:

  - a `delete` raised while an upsert runs vanishes, and the placeholder is
    written for an event the organiser has already deleted;
  - a **cancellation correction** raised while a plain upsert runs vanishes,
    and this one is permanent. Google reports a cancelled occurrence in exactly
    one delta, so nothing re-detects it, and the placeholder blocks the cleared
    slot for as long as the series lives.

  The obvious repair — dropping `:executing` from the uniqueness window so a
  new job is simply inserted — is the one the worker's moduledoc already
  refuses, and it is right to. Two jobs for one `{link, source event}` could
  then run at once in a queue with ten slots, both find no mapping, and both
  create a placeholder; `Engine`'s moduledoc documents that exact race and the
  orphan compensation that only partly contains it.

  So the conflict is answered rather than avoided. When the insert reports a
  conflict against a job that is *executing*, the intent is re-inserted as its
  own job, scheduled a short way out, under a uniqueness window narrowed to the
  pending states.

  Narrowing rather than disabling matters, and the difference was measured too.
  `unique: false` preserves the intent and loses the collapsing: one sync
  enqueues for the same pair twice — `MovedOccurrence.report/2` and then
  `enqueue_mirror_write_backs/3` — so a cancellation sync landing mid-run left
  *two* follow-ups, one carrying the correction and one not, and
  `WriteBackQueries.pending_moves/2`' `limit(1)` then read whichever Postgres
  returned first. Keeping the pending states in the window collapses the second
  deferral onto the first and lets `replace` rewrite its args, which is the same
  guarantee the ordinary path has: one pending job per pair, carrying the latest
  intent.

  Scheduling rather than making it available completes the argument. The
  follow-up becomes runnable after the job that blocked it rather than beside
  it, so one writer per placeholder still holds.

  A conflict against any *pending* state needs none of this — `replace` names
  those states, so the args were rewritten and the intent is already carried.
  """
  @spec enqueue(integer(), String.t(), operation(), keyword()) :: :ok
  def enqueue(sync_link_id, source_uid, operation, opts \\ [])

  def enqueue(sync_link_id, source_uid, operation, opts)
      when is_integer(sync_link_id) and is_binary(source_uid) and operation in [:upsert, :delete] and
             is_list(opts) do
    base = %{
      "sync_link_id" => sync_link_id,
      "source_uid" => source_uid,
      "operation" => Atom.to_string(operation)
    }

    args = put_moves(base, sync_link_id, source_uid, Keyword.get(opts, :moved))

    args
    |> SyncLinkWriteBackWorker.new(
      replace: [
        available: [:args],
        scheduled: [:args],
        retryable: [:args]
      ]
    )
    |> Oban.insert()
    |> defer_past_executing(args)
    |> log_enqueue_error(sync_link_id, source_uid)

    :ok
  end

  # The executing conflict, answered rather than swallowed. See the moduledoc:
  # Oban takes no fields for a state the `replace` does not name, so this insert
  # wrote nothing at all and the intent would otherwise be gone.
  #
  # The follow-up narrows the uniqueness window to the *pending* states, and
  # each half of that does one job:
  #
  # - dropping `:executing` is what lets the insert happen at all. The running
  #   job is the only reason the ordinary insert conflicted, and it is precisely
  #   the job this one is meant to follow.
  # - keeping the pending states is what stops the deferrals piling up. One sync
  #   enqueues for the same pair more than once — `MovedOccurrence.report/2` and
  #   then `enqueue_mirror_write_backs/3` — and without this every one of them
  #   would insert its own follow-up. They collapse onto the first instead, and
  #   `replace` rewrites its args, so the single deferred job carries the latest
  #   intent exactly as a pending job does on the ordinary path.
  #
  # Scheduling rather than making it available is the third half of the safety
  # argument: the follow-up becomes runnable after the job that blocked it
  # rather than beside it, so one writer per placeholder still holds.
  #
  # A conflict against a pending job is left alone: `replace` named that state,
  # so the args carry the new intent already.
  defp defer_past_executing({:ok, %Oban.Job{conflict?: true, state: "executing"}}, args) do
    args
    |> SyncLinkWriteBackWorker.new(
      unique: [
        keys: [:sync_link_id, :source_uid],
        states: [:available, :scheduled, :retryable]
      ],
      replace: [
        available: [:args],
        scheduled: [:args],
        retryable: [:args]
      ],
      schedule_in: @defer_seconds
    )
    |> Oban.insert()
  end

  defp defer_past_executing(result, _args), do: result

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
