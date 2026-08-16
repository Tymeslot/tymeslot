defmodule Tymeslot.Integrations.Calendar.SyncLink.ConflictLog do
  @moduledoc """
  Decides which divergence the engine is looking at, and records exactly one
  account of it.

  Split out of the engine because detection and writing are one decision made
  in three places — the update path, the delete path, and the terminal failure
  path — and spreading it means each of them classifies the same evidence
  slightly differently. The engine keeps the *write*; this keeps the *reading of
  what happened*.

  ## Why the placeholder's current state comes from the cache

  Asking the provider what the placeholder looks like now would be a round trip
  per event on every mirror pass, against a calendar whose quota is already
  shared with the paths that carry user-visible latency. The target's own
  inbound sync has already fetched it: the placeholder is an ordinary event on
  the target calendar, so it lands in `provider_calendar_events` under the
  target integration with its etag and `provider_updated_at` alongside. Reading
  it from there costs one indexed lookup and is exactly as current as the last
  sync of that calendar.

  The consequence to accept is that a direct edit is noticed on the pass after
  the target next syncs, not the instant it is made. That is the correct
  latency: the resolution is "the source overwrites it" either way, and a
  conflict noticed a sync later is still recorded with the values that were
  compared.

  ## Why absence of evidence is never a conflict

  A missing etag on either side, or a missing cache row, produces no conflict
  row at all. Providers differ in what they report — some send no etag, some no
  `provider_updated_at` — and treating "cannot tell" as "diverged" would append
  a row on every pass of every event for those providers, drowning the real
  divergences in a history that is mostly noise. A conflict is logged only when
  two values were compared and found to differ.

  ## The three etag-based kinds: closed for Google, off by design elsewhere

  `mirror_edited`, `both_changed` and `delete_race` each need a stored
  `target_etag` describing the placeholder *as written*. For a long time nothing
  could supply one and all three were dead in production. That is now closed for
  the providers that report an etag, and the shape of what remains is worth
  stating precisely, because "does not fire" means two different things
  depending on the provider.

  The write response carries the etag, and `SyncLink.WriteEtag` reads it out of
  whatever shape the write answered with. `OAuthBase.handle_write_api_call/2`
  is what keeps it: `convert_event/1` builds the availability layer's shape and
  drops every key it does not name, so the etag had to be preserved *before*
  that conversion narrowed the response. The engine then stamps it on the
  mapping row at every point a write lands — create, update, the 409
  create→update fallback, and the recreate of a hand-deleted placeholder.

  Per provider:

  - **Google** reports `etag` on every write response, so all three kinds fire.
  - **Outlook** sends `@odata.etag` on the raw Graph body and is read the same
    way; it is untested against the live API, so treat it as expected-to-work
    rather than confirmed.
  - **The CalDAV family** answers a bare `:ok` from a PUT whose response ETag
    the HTTP layer does not surface. It records `nil`.

  A `nil` baseline is a **stated rule, not an accident**: `mirror_edited?/2`
  below requires two binary etags, so the three etag-based kinds are simply off
  for a provider that reports none, and no arrangement of the cached placeholder
  can produce a row. That under-reporting is deliberate. The alternative is a
  false row per write per series, and this log is read when someone is trying to
  find out why a calendar looks wrong — it is worth less than nothing if most of
  what it holds is the engine reporting itself.

  Two shortcuts remain wrong, and are recorded so they are not retried:

  - **Reading the etag back from the cache.** That row holds what the target's
    last *inbound* sync fetched, which is the placeholder from *before* this
    write. Stamping it means the next pass compares our own change against a
    pre-change value and files the engine's write as a stranger's edit.
  - **Falling back to timestamps.** Our write stamps `last_synced_at`; the
    provider stamps `provider_updated_at` when it applies that same write,
    necessarily later. "Changed after our write" is therefore true of our own
    write as much as of a stranger's.

  `write_failed` and `occurrence_moved` never depended on a baseline and fire
  for every provider, unchanged.

  Closing the CalDAV remainder means surfacing the PUT response's ETag header
  through `CalDAV.Events.do_conditional_put/6` and the retry and circuit-breaker
  wrappers it sits behind, all of which currently narrow to `:ok`. That is a
  separate piece of work in the HTTP layer, not a change here.

  ## Why `series_exceptions` is no longer produced

  Nothing here writes that kind any more, and the reason is that the divergence
  it named has been fixed rather than merely stopped being interesting.

  It was introduced when a recurring source was mirrored from its master's RRULE
  alone. The master's `EXDATE` lines were read but dropped, so a series with two
  cancelled occurrences produced a placeholder that went on blocking two slots
  the organiser had already freed — a real, describable gap, and the row said so.
  The placeholder now carries those `EXDATE` lines. A cancelled occurrence is
  excluded on the target, the slot is bookable again, and there is nothing left
  for a row to report. Continuing to write one would tell the organiser to go
  looking for a discrepancy that is not there, which is worse than silence: it
  spends the credibility of the whole log, which is read precisely when someone
  is trying to find out why a calendar looks wrong.

  What the kind's wording also covered — a *moved* occurrence — is still a real
  divergence and is deliberately **not** reported in its place. It has its own
  kind, `occurrence_moved`, written by `SyncLink.MovedOccurrence` rather than
  from here, and the split is not bookkeeping. This module reads mirror state:
  a mapping row, a cached placeholder, two etags. A move is not visible in any
  of that. Google is fetched with `singleEvents=true` and every expanded
  instance shares one `iCalUID`, so `upsert_batch/1` collapses a series to a
  single cache row and the moved occurrence's new time is never stored — the
  only place it exists is the uncollapsed batch in
  `Sync.post_commit_reconciliation/2`, before the dedup, which is where that
  module runs.

  Reporting it from here instead would have meant firing on the evidence
  actually to hand: that the master has *any* exceptions. That fires on every
  cancellation too, which is the false report just removed wearing a vaguer
  sentence — a guess dressed as a finding, the thing `comparison/3` below
  already refuses to do about a winner it cannot name.

  So the kind stays valid in `CalendarSyncConflictSchema` and keeps its label in
  the dashboard, because the table is append-only and rows written before the
  EXDATEs were applied are still true about the placeholders of their time.
  Removing it from `@kinds` would not delete them; it would only make them
  render under the catch-all, which describes them worse than the name they were
  written with.

  ## Why a failed append is swallowed

  Every call site here sits beside a provider write that has already happened or
  has already failed. Turning a failure to write the *audit* into a failure of
  the operation would mean a placeholder correctly written on the target is
  reported as an error, retried, and written again — the audit costing the
  correctness it exists to describe. So an append that fails is logged at
  warning and the operation's own outcome stands.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  # Written into `target_etag` once a divergence has been logged, so the retry
  # that follows does not log it again. A real etag is a provider value and
  # `nil` means "no baseline yet"; this is neither, and no provider can produce
  # it. Exposed because the engine is what stamps it and this module is what
  # reads it — a literal in both places would be two facts that must agree.
  @consumed_baseline "tymeslot:recorded"

  @typedoc "The provider write a terminal failure was attempting."
  @type operation :: :create | :update | :delete

  @doc "The sentinel a recorded divergence leaves in place of a baseline."
  @spec consumed_baseline() :: String.t()
  def consumed_baseline, do: @consumed_baseline

  @doc """
  Records the divergence an about-to-be-overwritten placeholder represents, if
  there is one.

  The resolution is not conditional on the answer: the source overwrites the
  placeholder whether or not anything is recorded. Only the account of it is at
  stake, and the caller re-stamps the baseline immediately afterwards, so a
  second call has nothing left to compare and the same divergence cannot be
  appended twice.
  """
  @spec record_overwrite(CalendarSyncMirrorSchema.t(), map()) :: :ok
  def record_overwrite(%CalendarSyncMirrorSchema{} = mirror, source_event) do
    observed = observed_placeholder(mirror)

    if observed && mirror_edited?(mirror, observed) do
      log_divergence(mirror, source_event, observed)
    else
      :ok
    end
  end

  @doc """
  Records a source deletion that raced an edit to the placeholder.

  The deletion wins regardless — a placeholder whose source no longer exists is
  blocking time for nothing — so this decides only whether the organiser is told
  that the edit they made was destroyed rather than merely reverted.

  Answers whether a row was written, because the caller has to know: a delete
  the provider refuses leaves the mapping behind for the sweep to retry, and the
  evidence the race was read from is still there for the retry to read again.
  The caller consumes the baseline once a row exists, so one race stays one row.
  """
  @spec record_delete_race(CalendarSyncMirrorSchema.t()) :: :recorded | :nothing_to_record
  def record_delete_race(%CalendarSyncMirrorSchema{} = mirror) do
    observed = observed_placeholder(mirror)

    if observed && mirror_edited?(mirror, observed) do
      append(mirror, "delete_race", "deletion_won", %{
        "target_etag_written" => mirror.target_etag,
        "target_etag_observed" => observed.etag,
        "target_updated_at" => iso8601(observed.provider_updated_at),
        "last_synced_at" => iso8601(mirror.last_synced_at)
      })

      :recorded
    else
      :nothing_to_record
    end
  end

  @doc """
  Records a provider write that has run out of attempts.

  Only the last attempt writes a row. An error Oban will retry is not a
  resolution but a write still in flight, and recording each attempt would fill
  the history with rows for writes that went on to succeed seconds later.
  """
  @spec record_write_failure(integer(), String.t(), operation(), term()) :: :ok
  def record_write_failure(sync_link_id, source_uid, operation, reason)
      when is_integer(sync_link_id) and is_binary(source_uid) do
    append_attrs(
      %{
        sync_link_id: sync_link_id,
        source_uid: source_uid,
        kind: "write_failed",
        resolution: "skipped",
        detail: %{
          "operation" => Atom.to_string(operation),
          "error" => describe(reason)
        }
      },
      sync_link_id,
      source_uid
    )
  end

  # `both_changed` and `mirror_edited` are the same evidence read twice: the
  # placeholder has moved, and the question is only whether the source moved
  # too. Deciding it here rather than at two call sites is what keeps a single
  # divergence from being appended under both names.
  defp log_divergence(mirror, source_event, observed) do
    if source_changed?(mirror, source_event) do
      append(
        mirror,
        "both_changed",
        "source_won",
        Map.merge(comparison(mirror, source_event, observed), %{
          "target_etag_written" => mirror.target_etag,
          "target_etag_observed" => observed.etag
        })
      )
    else
      append(mirror, "mirror_edited", "source_won", %{
        "target_etag_written" => mirror.target_etag,
        "target_etag_observed" => observed.etag,
        "target_updated_at" => iso8601(observed.provider_updated_at),
        "last_synced_at" => iso8601(mirror.last_synced_at)
      })
    end
  end

  # Which side is newer, and by what evidence. The winner is recorded even
  # though the source overwrites either way: an organiser reading a row where
  # the target was newer is reading the one resolution that destroyed work they
  # did, and that has to be distinguishable from the one that did not.
  defp comparison(mirror, source_event, observed) do
    source_at = Map.get(source_event, :provider_updated_at)
    target_at = observed.provider_updated_at

    base = %{
      "source_updated_at" => iso8601(source_at),
      "target_updated_at" => iso8601(target_at),
      "last_synced_at" => iso8601(mirror.last_synced_at)
    }

    case {source_at, target_at} do
      {%DateTime{}, %DateTime{}} ->
        Map.merge(base, %{
          "compared_by" => "provider_updated_at",
          "winner" => winner(source_at, target_at)
        })

      # No timestamp on one side or the other leaves only etag inequality, which
      # says both moved but not which moved last. Naming the winner from that
      # would be a guess dressed as a finding.
      _no_timestamp ->
        Map.merge(base, %{
          "compared_by" => "etag",
          "winner" => "unknown",
          "source_etag_written" => mirror.source_etag,
          "source_etag_observed" => Map.get(source_event, :etag),
          "target_etag_written" => mirror.target_etag,
          "target_etag_observed" => observed.etag
        })
    end
  end

  defp winner(source_at, target_at) do
    case DateTime.compare(source_at, target_at) do
      :lt -> "target"
      _source_at_least_as_new -> "source"
    end
  end

  # The placeholder as the target's own sync last cached it. A target that has
  # not synced since the placeholder was written has no row, which is not
  # evidence of anything.
  defp observed_placeholder(%CalendarSyncMirrorSchema{} = mirror) do
    case ProviderCalendarEventQueries.get_by_uid(mirror.target_integration_id, mirror.target_uid) do
      {:ok, event} -> event
      {:error, :not_found} -> nil
    end
  end

  # Both etags must be present to differ. A provider reporting none gives
  # nothing to compare, and "changed" is not the safe reading of that.
  #
  # The second half is what keeps the engine's own write from looking like a
  # direct edit. Writing the placeholder bumps its etag on the provider, so the
  # target's next inbound sync caches an etag that differs from the one recorded
  # at the previous write — through no organiser's doing. A change stamped no
  # later than that write is therefore the write itself, and only one stamped
  # after it is somebody else's edit.
  # A divergence already recorded, and deliberately not recorded twice. The
  # engine stamps this after logging a delete race, because the race survives
  # into the retry — the placeholder's cached state does not change just because
  # our delete failed — and one race is one event however many attempts it takes.
  defp mirror_edited?(%{target_etag: @consumed_baseline}, _observed), do: false

  defp mirror_edited?(%{target_etag: written} = mirror, %{etag: observed} = placeholder)
       when is_binary(written) and is_binary(observed),
       do: written != observed and changed_after_write?(mirror, placeholder)

  defp mirror_edited?(_mirror, _observed), do: false

  defp changed_after_write?(%{last_synced_at: %DateTime{} = written_at}, %{
         provider_updated_at: %DateTime{} = observed_at
       }),
       do: DateTime.compare(observed_at, written_at) == :gt

  # A target that reports no `provider_updated_at`, or a mapping written before
  # the stamp existed, leaves the etag as the only signal there is. Suppressing
  # the conflict there would mean such a provider never records one at all,
  # which is a worse answer than the occasional row attributable to a write the
  # engine made itself.
  defp changed_after_write?(_mirror, _placeholder), do: true

  # The source moved since the mapping was last written from it. Timestamps
  # first, because they order the two changes; etags only say they differ.
  defp source_changed?(%{source_updated_at: %DateTime{} = mapped}, %{
         provider_updated_at: %DateTime{} = current
       }),
       do: DateTime.compare(current, mapped) == :gt

  defp source_changed?(%{source_etag: mapped}, source_event)
       when is_binary(mapped) do
    case Map.get(source_event, :etag) do
      current when is_binary(current) -> current != mapped
      _no_etag -> false
    end
  end

  defp source_changed?(_mirror, _source_event), do: false

  defp append(%CalendarSyncMirrorSchema{} = mirror, kind, resolution, detail) do
    append_attrs(
      %{
        sync_link_id: mirror.sync_link_id,
        source_uid: mirror.source_uid,
        kind: kind,
        resolution: resolution,
        detail: detail
      },
      mirror.sync_link_id,
      mirror.source_uid
    )
  end

  defp append_attrs(attrs, sync_link_id, source_uid) do
    case CalendarSyncConflictQueries.append(attrs) do
      {:ok, _conflict} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to record calendar sync conflict",
          sync_link_id: sync_link_id,
          source_uid: source_uid,
          kind: Map.get(attrs, :kind),
          reason: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(_absent), do: nil

  # `detail` is serialised to JSONB, so the reason has to survive as a string.
  # `inspect/1` rather than `to_string/1` because a provider error is as often a
  # tuple as an atom, and `to_string/1` raises on the former.
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
