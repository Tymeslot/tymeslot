defmodule Tymeslot.Integrations.Calendar.SyncLink.MirrorRow do
  @moduledoc """
  Moves the mapping row along after a provider write has already landed, under
  the one rule that makes it safe to do so: none of it may fail the write.

  Split out of `SyncLink.Engine` for the same reason `SyncLink.MirrorColour`
  was, and it is the mirror image of that split. The engine's entire return
  contract is that a failure propagates — `{:error, reason}` reaches the worker,
  Oban retries, the write is attempted again. Every function here breaks that
  contract deliberately, and the break is the point: by the time any of them
  runs, the placeholder on the organiser's calendar is *already correct*. The
  row is Tymeslot's private note about a write the provider has accepted, and
  turning a failed note into a failed write would re-send a placeholder that
  needs nothing, burning provider quota to fix a bookkeeping entry.

  Keeping these inline in the engine made that read as an oversight — a `case`
  that quietly drops its error looks like a missing branch until you know why
  it is missing. Gathered here, the rule is stated once and every function in
  the module is visibly an instance of it.

  ## What a stale row costs, and why that is the cheaper failure

  A row that falls behind is a state the system already handles.
  `SyncLinkReconcileWorker` sweeps the mapping rows and re-derives the write
  from them, so a row left saying `active` when it should say `failed`, or one
  still naming an id the provider has superseded, is corrected on the next
  pass. That is a bounded window measured in minutes.

  The alternative is unbounded. Propagating the error retries the whole mirror,
  and the retry re-runs the provider write — which succeeds again, because it
  succeeded the first time — and then attempts the same row update, which fails
  again for whatever reason it failed before (a constraint, a connection, a row
  deleted underneath). Five attempts later Oban gives up having written the
  placeholder five times. Every failure here is therefore logged and swallowed,
  which is what leaves the sweep as the single mechanism that reconciles rows.

  ## Why the deletes are the exception

  `drop/1` is the one function here that *does* surface its error, and the
  asymmetry is deliberate. Everything else adjusts a row that will keep
  describing a placeholder either way. Dropping the row is the last step of
  withdrawing one, and the row holds the `target_uid` — the only thing naming
  the placeholder on the provider. A drop that fails and reports success
  strands nothing, but it does end the operation claiming a withdrawal that the
  caller cannot verify. Teardown and the sync path both need to know, because
  both are destructive and both leave the row in `pending_delete` for the sweep
  when they cannot finish.

  ## The etag baseline used to live here

  A `baseline_after_write/0` once sat in this module and answered a constant
  `nil`, because at the time the placeholder's post-write etag existed nowhere
  the engine could reach: the write response carried it and was discarded before
  the engine saw it. Reading it back from the cache instead would have recorded
  the *pre*-write value and reported the engine's own write as a stranger's
  edit, so `nil` — "no baseline" — was the honest answer, at the cost of the
  three etag-based conflict kinds never firing.

  The write response now carries it (`SyncLink.WriteEtag`), so the engine stamps
  the real value and the placeholder is gone rather than left as a function that
  no longer decides anything. Nothing about *this* module's rule changed: the
  column is still set on a row write that may not fail the provider write.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema

  @doc """
  Applies `attrs` to the mapping row, answering the row either way.

  The updated struct on success, the row *as it was* on failure — never an
  error tuple, so a caller can pipe this straight through without deciding what
  a bookkeeping failure means. It means nothing to the caller; see the
  moduledoc. Answering the unchanged row rather than `nil` keeps a caller that
  reads a field off the result working on the stale value instead of crashing,
  which matches what the row on disk now says.
  """
  @spec mark(CalendarSyncMirrorSchema.t(), map()) :: CalendarSyncMirrorSchema.t()
  def mark(%CalendarSyncMirrorSchema{} = mirror, attrs) do
    case CalendarSyncMirrorQueries.update(mirror, attrs) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning("Failed to update mirror mapping state",
          sync_link_id: mirror.sync_link_id,
          source_uid: mirror.source_uid,
          reason: inspect(changeset.errors)
        )

        mirror
    end
  end

  @doc """
  Drops the mapping row once its placeholder is confirmed gone from the
  provider.

  Surfaces its error, unlike the rest of this module — see the moduledoc on why
  the withdrawal path is the exception.
  """
  @spec drop(CalendarSyncMirrorSchema.t()) :: :ok | {:error, term()}
  def drop(%CalendarSyncMirrorSchema{} = mirror) do
    case CalendarSyncMirrorQueries.delete(mirror) do
      {:ok, _deleted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parks the row in `pending_delete` and hands back the provider failure that
  put it there.

  The two halves are one step: the state is what the reconcile sweep looks for,
  and the error is what tells the caller the placeholder is still standing. A
  caller that got only the state would report a withdrawal that did not happen.
  """
  @spec mark_pending_delete(CalendarSyncMirrorSchema.t(), term()) :: {:error, term()}
  def mark_pending_delete(%CalendarSyncMirrorSchema{} = mirror, reason) do
    mark(mirror, %{state: "pending_delete"})
    {:error, reason}
  end
end
