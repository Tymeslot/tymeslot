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

  ## Which cache row, and in what form its etag arrives

  Two facts about the target side make that lookup and that comparison harder
  than they look, and both were wrong here at once — the first hiding the
  second, so fixing either alone would have been worse than fixing neither.

  The placeholder is not cached under the UID the write was addressed to.
  Google mints its own iCalUID as `{id}@google.com` and the normaliser caches
  that, so `target_uid` names a row that exists only for the CalDAV family,
  which keeps the UID it is handed. Both identities are tried, through the one
  statement of that expansion in `SyncLink.ProviderEventId`.

  And the two etags are not in the same form. The mirror's is cleaned on the way
  in by `SyncLink.WriteEtag`; the cache's is Google's raw entity tag, quotes
  included. They are cleaned to a common form at the moment of comparison, in
  the single function that performs it — see `etags_differ?/2` below for why
  that side and not the cache column.

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
  - **Outlook** supplies the write half only, and the three kinds stay off for
    it. Graph annotates every entity with `@odata.etag`, and the write path now
    keeps it — `CalendarAPI.convert_to_common_format/1` narrows a write response
    to a fixed atom-keyed map before `handle_write_api_call/2` ever sees it, so
    the key had to be named there or it was gone one layer too early. It was
    not, and every Outlook mirror row stored a `nil` baseline.

    That is necessary but not sufficient. `mirror_edited?/2` needs *two* binary
    etags plus a `provider_updated_at`, and the cache side supplies neither:
    `Outlook.EventNormaliser` maps no `etag` and no `provider_updated_at`
    (contrast `Google.EventNormaliser`'s `event_normaliser.ex:82-83`), and the
    inbound `$select` (`outlook_calendar_api.ex:29`) requests
    `lastModifiedDateTime` no more than it does the etag. Closing the read half
    means both a `$select` change and new normaliser mappings, verifiable only
    against a live tenant. Until then Outlook behaves like the CalDAV family
    here — off, by absence of a baseline on the observed side rather than the
    written one.
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
  - **Falling back to timestamps *of the change*.** Our write stamps
    `last_synced_at`; the provider stamps `provider_updated_at` when it applies
    that same write, necessarily later. "Changed after our write" is therefore
    true of our own write as much as of a stranger's. This was written down here
    and then built anyway: `changed_after_write?/2` compared exactly that pair,
    and every mirror pass inside the window below read the engine's own write as
    an edit.

  What does separate them is the timestamp of the *observation* rather than of
  the change. The cached placeholder is only evidence about a state later than
  our write if it was fetched later than our write, so the comparison is the
  cache row's `synced_at` against the mapping's `updated_at` — see
  `changed_after_write?/2`. The failure it closes is a loop, not a stray row:
  the resolution for a divergence is to rewrite the placeholder, which mints a
  new etag that the stale cache still does not match, so the next pass finds the
  same divergence again. One live mirror wrote 40 `mirror_edited` rows in 17
  seconds and stopped only when the target's inbound sync finally ran, half an
  hour later — the rows show `target_etag_observed` frozen while
  `target_etag_written` advanced, which is that loop's signature.

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

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.ProviderEventId

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
  #
  # Looked up under every identity the placeholder could be cached under rather
  # than under `target_uid` alone, because Google does not keep the UID a write
  # was addressed to — it mints `{id}@google.com` and the normaliser caches that.
  # `target_uid` therefore names a row that exists only for the CalDAV family,
  # and asking for it alone found nothing at all on a live installation: 0 of 105
  # active mirrors resolved, all 105 resolved by the suffixed provider id. Every
  # etag-based kind was dead for a Google target as a result, and the suite was
  # green because its fixtures cached the placeholder under the uid we asked for.
  #
  # `ProviderEventId.cache_identities/2` is the one statement of that expansion,
  # shared with loop prevention in `CalendarSyncMirrorQueries`. Its order puts
  # the form live rows actually carry first, so the ordinary case is one query.
  defp observed_placeholder(%CalendarSyncMirrorSchema{} = mirror) do
    mirror.target_uid
    |> ProviderEventId.cache_identities(mirror.target_provider_event_id)
    |> Enum.find_value(fn uid ->
      case ProviderCalendarEventQueries.get_by_uid(mirror.target_integration_id, uid) do
        {:ok, event} -> event
        {:error, :not_found} -> nil
      end
    end)
  end

  # Both etags must be present to differ. A provider reporting none gives
  # nothing to compare, and "changed" is not the safe reading of that.
  #
  # The second half is what keeps the engine's own write from looking like a
  # direct edit, and the question it has to answer is not "did the placeholder
  # change after our write" but "have we *learned* anything about the
  # placeholder since our write". Those come apart precisely in the window this
  # guard exists for.

  # A divergence already recorded, and deliberately not recorded twice. The
  # engine stamps this after logging a delete race, because the race survives
  # into the retry — the placeholder's cached state does not change just because
  # our delete failed — and one race is one event however many attempts it takes.
  defp mirror_edited?(%{target_etag: @consumed_baseline}, _observed), do: false

  defp mirror_edited?(%{target_etag: written} = mirror, %{etag: observed} = placeholder)
       when is_binary(written) and is_binary(observed),
       do: etags_differ?(written, observed) and changed_after_write?(mirror, placeholder)

  defp mirror_edited?(_mirror, _observed), do: false

  # The only place the two target etags are compared, which is the point of it
  # existing rather than a `!=` at the call site above.
  #
  # They arrive in different forms and always have. `WriteEtag.extract/1` cleans
  # the write response's entity tag before it reaches `target_etag`, so the
  # mirror row holds `3573898397004446`; `Google.EventNormaliser` stores
  # `raw["etag"]` untouched (`event_normaliser.ex:82`), so the cache row holds
  # `"3573898397004446"` with Google's quotes. On a live installation all 105
  # mirror rows carried the bare form and all 224 cached events the quoted one,
  # so a raw `!=` is unequal for every pair including the matching ones — a
  # conflict row per mirror per sweep, the entire log filled with the engine
  # reporting its own writes.
  #
  # Normalised here rather than on the way into the cache for two reasons. The
  # rows already written are the ones that matter: 224 of them hold the quoted
  # form, and cleaning only new writes would leave every existing placeholder
  # comparing unequal until its calendar next re-syncs — which for an unchanged
  # event under Google's delta sync may be never. And the cache's `etag` is a
  # provider value read by paths that are not this one, so trimming it there
  # changes what they see to fix a comparison that is local to here.
  #
  # `clean_etag/1` is the same function `WriteEtag` delegates to, so the two
  # sides cannot drift into disagreeing about what "cleaned" means — including
  # over a weak tag like Graph's `W/"abc"`, which it trims untidily but trims
  # identically on both sides.
  defp etags_differ?(written, observed),
    do: EventProcessor.clean_etag(written) != EventProcessor.clean_etag(observed)

  # The cached placeholder is an *observation*, and it is only evidence about a
  # state later than our own write if it was fetched later than our own write.
  # `synced_at` is when the target's inbound sync last learned anything about
  # this placeholder; `updated_at` is when we last wrote the mapping. An
  # observation older than our write describes the placeholder as it was
  # *before* it, so an etag difference is our own un-synced write and nothing
  # else — which is the whole of the defect this guard now closes.
  #
  # `provider_updated_at` cannot stand in for `synced_at`, and standing it in is
  # what flooded the live installation. It records when the provider *applied* a
  # change, and the provider applies our write moments after we record the row
  # that issued it — measured at 10:01:30.311 against a mapping stamped
  # 10:01:30.446, so our own write reads as "changed after our write" on the
  # very next pass. That is the trap this module's moduledoc already names under
  # "Falling back to timestamps"; the guard was written against the wrong half of
  # it. The target then syncs on its own schedule, up to 30 minutes later, and
  # for that whole window the cache holds the pre-write etag while every pass
  # rewrites the placeholder and mints another — 40 rows in 17 seconds for one
  # mirror, the observed etag frozen while the written one advanced.
  #
  # Stated once here rather than at each call site because `record_overwrite/2`
  # and `record_delete_race/1` read the same observation through this predicate:
  # `mirror_edited`, `both_changed` and `delete_race` all had the hole, and one
  # statement is what keeps them from drifting into disagreeing about it.
  defp changed_after_write?(%{updated_at: %DateTime{} = written_at}, %{
         synced_at: %DateTime{} = observed_at
       }),
       do: DateTime.compare(observed_at, written_at) == :gt

  # `synced_at` is required on every cache row and the mapping's `updated_at` is
  # a timestamp column, so neither is normally absent. Where one is — a row built
  # in a test, or a mapping predating the column — the etag is the only signal
  # there is, and suppressing the conflict would mean never recording one at all.
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
