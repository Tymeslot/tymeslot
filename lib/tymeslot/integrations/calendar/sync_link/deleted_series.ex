defmodule Tymeslot.Integrations.Calendar.SyncLink.DeletedSeries do
  @moduledoc """
  Retires a recurring series the organiser has deleted: the placeholder on the
  target, and the source's own cache row.

  ## Why the cache row is the half that gets missed

  Deleting a Google series emits one six-key tombstone **per occurrence**, and
  every one of them carries `recurringEventId`.
  `SyncGoogleCalendarWorker.withdrawn?/1` deliberately keeps such an event off
  the deletion path, because withdrawing by uid would take a whole series down
  in order to free the one occurrence that was cancelled — the regression
  `5d1a4ded` exists to prevent.

  That is right, and it is also why a deleted series left its cache row
  standing. Nothing on the sync path removes it, and a `confirmed` row is
  `CalendarEvent.blocking?/1`, so the organiser's own availability went on being
  blocked by a series that no longer exists — a symptom quite separate from the
  mirror, and one that survives having no sync links at all.

  ## Why it is decided here rather than on the sync path

  Nothing in a tombstone can say which case it is. A deleted series' tombstone
  and a single cancelled occurrence's are **element-wise identical**, and the
  batch is no better a witness: a delta is paginated and windowed, so "every
  occurrence was cancelled" is not a question one page can answer.

  The master can answer it, and answers plainly — a deleted series' master comes
  back with `status: "cancelled"`, not a 404 (see `SyncLink.RecurringSeries`).
  But the master is a provider call, and putting one on the inbound sync path
  would let a mirror-side failure abandon a whole delta and its sync token. So
  the question is asked where the master is *already* fetched: the write-back
  job, where a failure costs one retry of one mirror and nothing else.

  ## Why the source row is deleted through the query module

  Removing a **source** cache row from the mirror layer is a deliberate
  exception to the usual ownership split, in which `Sync` owns the cache and
  this layer owns placeholders. It goes through `ProviderCalendarEventQueries`
  rather than `Sync.reconcile_deletions/3` because `Sync` already depends on
  this layer, and calling back into it would close a cycle.

  The delete is idempotent and keyed by uid, so a series mirrored onto three
  targets has its row removed by whichever link runs first and the other two
  find nothing.
  """

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  @doc """
  Withdraws the placeholder and drops the source's cache row.

  `withdraw` is the caller's own `unmirror`, applied first: the mapping row
  holds the `target_uid` that identifies the placeholder, so the cache row is
  only dropped once the withdrawal has had its turn. Its result is returned
  unchanged, including a failure — a provider that refused the delete leaves the
  mapping in `pending_delete` for the reconcile sweep, and the caller's retry
  ladder is what acts on that.

  The cache row goes either way. It describes a series the provider has already
  said is gone, and keeping it because the *target* write failed would leave the
  source blocking availability for a reason that has nothing to do with it.
  """
  @spec retire(integer(), String.t(), (-> result)) :: result when result: var
  def retire(source_integration_id, source_uid, withdraw)
      when is_integer(source_integration_id) and is_binary(source_uid) and
             is_function(withdraw, 0) do
    result = withdraw.()

    ProviderCalendarEventQueries.delete_by_uid(source_integration_id, source_uid)

    result
  end
end
