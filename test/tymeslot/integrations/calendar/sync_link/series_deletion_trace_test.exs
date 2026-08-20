defmodule Tymeslot.Integrations.Calendar.SyncLink.SeriesDeletionTraceTest do
  @moduledoc """
  A trace of what happens when a Google recurring **series** is deleted at the
  source, hop by hop, driven through the real sync path with the captured
  payload shapes.

  This module is diagnostic rather than regulatory. Each test names one hop of
  the deletion path and asserts what the code does *today*, so a single fix can
  be measured against the whole path instead of against its first blocker. A
  test whose assertion documents a defect says so in its name and its comment;
  the ones that pass on correct behaviour are just as load-bearing, because a
  clean hop is the result that stops it being re-checked.

  Every payload comes from `Tymeslot.GoogleDeltaFixtures`, transcribed from
  `test/support/captured/google_recurring_series.md`. Deleting a master emits
  one six-key tombstone **per occurrence** — no `iCalUID`, no `start`/`end`,
  `recurringEventId` present on every one — because the delta runs with
  `singleEvents=true` and Google never returns masters under it.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  import Tymeslot.GoogleDeltaFixtures
  import Tymeslot.SeriesDeletionTraceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncLinkReconcileWorker
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  # The three occurrences the captured series had.
  @master_id Tymeslot.SeriesDeletionTraceHelpers.master_id()
  @series_uid Tymeslot.SeriesDeletionTraceHelpers.series_uid()

  @occ_1 "2026-08-24T09:00:00Z"
  @occ_2 "2026-08-31T09:00:00Z"
  @occ_3 "2026-09-07T09:00:00Z"
  @occurrences [@occ_1, @occ_2, @occ_3]

  setup do
    sync_link_world()
  end

  defp sync(source, events) do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: events, next_sync_token: "token-1"}}
    end)

    perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => source.id})
  end

  defp deletion_tombstones, do: google_delta_series_deletion(@master_id, @occurrences)

  defp write_back_jobs, do: all_enqueued(worker: SyncLinkWriteBackWorker)

  defp jobs_for(uid), do: Enum.filter(write_back_jobs(), &(&1.args["source_uid"] == uid))

  # Hops H, J and I — the batch-level questions — live in
  # `SeriesDeletionBatchTraceTest`.

  # ------------------------------------------------------------------
  # Hop A — routing
  # ------------------------------------------------------------------

  describe "hop A: routing a deleted series' tombstones" do
    # DEFECT 1. `withdrawn?/1` (sync_google_calendar_worker.ex:372-375) answers
    # true only when `recurringEventId` is absent. Every tombstone of a deleted
    # series carries it, so none is routed to `reconcile_deletions/3` at all.
    test "no tombstone of a deleted series reaches the deletion path", %{source: source} do
      cache_the_series(source)
      tombstones = deletion_tombstones()

      assert length(tombstones) == 3, "expected the captured 3-occurrence series"

      assert Enum.count(tombstones, &is_binary(&1["recurringEventId"])) == 3,
             "all 3 tombstones carry recurringEventId — that is what misroutes them"

      assert :ok = sync(source, tombstones)

      # Reaching the deletion path would have removed the cache row. It survives,
      # which is the observable proof the tombstones went the other way.
      assert [row] = cached_rows(source)
      assert row.uid == @series_uid
      assert row.status == "confirmed"
    end

    # Hop A, control: a genuinely deleted ONE-OFF still routes correctly. This
    # is hop I's regression guard stated at the routing seam.
    test "a cancelled one-off with no recurringEventId does reach it", %{source: source} do
      insert(:provider_calendar_event,
        calendar_integration: source,
        uid: "one-off@google.com",
        provider: "google",
        provider_event_id: "one-off",
        status: "confirmed"
      )

      one_off = %{
        "id" => "one-off",
        "iCalUID" => "one-off@google.com",
        "kind" => "calendar#event",
        "status" => "cancelled"
      }

      assert :ok = sync(source, [one_off])

      assert cached_rows(source) == [],
             "the one-off deletion path is intact and removes its cache row"
    end
  end

  # ------------------------------------------------------------------
  # Hop B — what ref could even be built
  # ------------------------------------------------------------------

  describe "hop B: the deletion ref a tombstone can produce" do
    # DEFECT 2. `process_cancelled_event/2` (:377-381) reads `event["iCalUID"]`,
    # which a tombstone does not have. Asserted against the fixture directly so
    # the claim is about the payload, not about a mock.
    test "iCalUID is absent from every tombstone, so the ref's uid is nil" do
      tombstones = deletion_tombstones()

      assert Enum.count(tombstones, &is_nil(&1["iCalUID"])) == 3

      refs = Enum.map(tombstones, &%{provider_event_id: &1["id"], uid: &1["iCalUID"]})

      assert Enum.all?(refs, &is_nil(&1.uid))

      assert Enum.map(refs, & &1.provider_event_id) == [
               "#{@master_id}_20260824T090000Z",
               "#{@master_id}_20260831T090000Z",
               "#{@master_id}_20260907T090000Z"
             ]
    end

    # The helper that recovers the series uid works, and works from any of the
    # three tombstones, because they all name the same master. This hop is
    # CLEAN — the machinery to build a correct ref already exists.
    test "series_uid_for_master resolves the uid from the cached series",
         %{source: source} do
      cache_the_series(source)

      for tombstone <- deletion_tombstones() do
        assert {:ok, @series_uid} =
                 ProviderCalendarEventQueries.series_uid_for_master(
                   source.id,
                   tombstone["recurringEventId"]
                 )
      end
    end

    # And fails closed when nothing is cached — which matters for hop F.
    test "it answers :not_found when the series is not cached", %{source: source} do
      assert {:error, :not_found} =
               ProviderCalendarEventQueries.series_uid_for_master(source.id, @master_id)
    end
  end

  # ------------------------------------------------------------------
  # Hop C — cache deletion, driven with the refs a fixed routing would build
  # ------------------------------------------------------------------

  describe "hop C: deleting the cache row with N refs for one series" do
    # Feeding `reconcile_deletions/3` the refs a corrected `process_cancelled_event`
    # would build. One series row, three refs — the second and third find nothing.
    test "three refs carrying the series uid delete the one row idempotently",
         %{source: source} do
      cache_the_series(source)
      assert length(cached_rows(source)) == 1

      refs =
        Enum.map(deletion_tombstones(), fn t ->
          %{provider_event_id: t["id"], uid: @series_uid}
        end)

      assert :ok = Sync.reconcile_deletions(source, refs)

      assert cached_rows(source) == [],
             "the series row is gone and the repeats did not error"
    end

    # With `uid: nil`, `delete_cached_event/3` falls through to the
    # `provider_event_id` clause. Whether that reaches the row is an ACCIDENT of
    # which occurrence `upsert_batch/1` happened to keep last.
    #
    # The cached series row's `provider_event_id` is the last occurrence's
    # instance id, so the third tombstone matches it and the row does go. Any
    # deletion whose batch does not happen to contain that exact instance
    # leaves the row standing — the next test is the same code with the last
    # occurrence omitted, and there the row survives.
    test "refs carrying only the instance id delete by luck when the last occurrence is present",
         %{source: source} do
      row = cache_the_series(source)
      assert row.provider_event_id == "#{@master_id}_20260907T090000Z"

      refs =
        Enum.map(deletion_tombstones(), fn t ->
          %{provider_event_id: t["id"], uid: nil}
        end)

      assert Enum.any?(refs, &(&1.provider_event_id == row.provider_event_id)),
             "this batch happens to contain the instance the cache row is keyed by"

      assert :ok = Sync.reconcile_deletions(source, refs)

      assert cached_rows(source) == []
    end

    # DEFECT: the same code, one occurrence short. Google sends a tombstone per
    # occurrence, but a delta is paginated and windowed — a batch that does not
    # contain the exact instance the cache row was keyed by deletes nothing.
    test "refs carrying only the instance id delete nothing when it is absent",
         %{source: source} do
      row = cache_the_series(source)

      refs =
        deletion_tombstones()
        |> Enum.reject(&(&1["id"] == row.provider_event_id))
        |> Enum.map(&%{provider_event_id: &1["id"], uid: nil})

      assert length(refs) == 2

      assert :ok = Sync.reconcile_deletions(source, refs)

      assert [survivor] = cached_rows(source)

      assert survivor.uid == @series_uid,
             "the instance-id clause cannot reach a row keyed by the series uid"
    end
  end

  # ------------------------------------------------------------------
  # Hop D — the withdrawal enqueue
  # ------------------------------------------------------------------

  describe "hop D: enqueueing the mirror withdrawal" do
    test "N refs for one series collapse to a single :delete job per link",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      refs =
        Enum.map(deletion_tombstones(), fn t ->
          %{provider_event_id: t["id"], uid: @series_uid}
        end)

      assert :ok = Sync.reconcile_deletions(source, refs)

      jobs = jobs_for(@series_uid)

      assert length(jobs) == 1,
             "expected uniqueness to collapse 3 enqueues, got #{length(jobs)}"

      assert hd(jobs).args["operation"] == "delete"
    end

    # The `is_binary/1` filter in `enqueue_mirror_withdrawals` (sync.ex:387-391)
    # drops a nil-uid ref outright, so no withdrawal is enqueued at all.
    test "refs with a nil uid enqueue nothing", %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      refs =
        Enum.map(deletion_tombstones(), fn t ->
          %{provider_event_id: t["id"], uid: nil}
        end)

      assert :ok = Sync.reconcile_deletions(source, refs)

      assert jobs_for(@series_uid) == []
    end
  end

  # ------------------------------------------------------------------
  # Hop E — the delete write-back executing
  # ------------------------------------------------------------------

  describe "hop E: the delete write-back withdraws the placeholder" do
    test "a successful provider delete drops the mapping row",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror = mirror_the_series(link)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok =
               perform_job(SyncLinkWriteBackWorker, %{
                 "sync_link_id" => link.id,
                 "source_uid" => @series_uid,
                 "operation" => "delete"
               })

      assert {:error, :not_found} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, mirror.source_uid)
    end

    # The placeholder already gone from the provider. `delete_mirror/4` treats
    # a 404 as done and drops the row, which is what stops the sweep retrying
    # a delete that can never succeed.
    test "a provider 404 also drops the mapping row", %{source: source, link: link} do
      cache_the_series(source)
      mirror = mirror_the_series(link)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :not_found}
      end)

      assert :ok =
               perform_job(SyncLinkWriteBackWorker, %{
                 "sync_link_id" => link.id,
                 "source_uid" => @series_uid,
                 "operation" => "delete"
               })

      assert {:error, :not_found} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, mirror.source_uid)
    end

    # A failure leaves the row in `pending_delete`, which is what the sweep's
    # `finish_withdrawals/1` re-enqueues from.
    test "a provider failure leaves the row pending_delete", %{source: source, link: link} do
      cache_the_series(source)
      mirror = mirror_the_series(link)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :network_error}
      end)

      assert {:error, :network_error} =
               perform_job(SyncLinkWriteBackWorker, %{
                 "sync_link_id" => link.id,
                 "source_uid" => @series_uid,
                 "operation" => "delete"
               })

      assert {:ok, reloaded} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, mirror.source_uid)

      assert reloaded.state == CalendarSyncMirrorSchema.state_pending_delete()
    end
  end

  # ------------------------------------------------------------------
  # Hop F — the ordering hazard
  # ------------------------------------------------------------------

  describe "hop F: reconcile_deletions deletes the cache row before enqueueing" do
    # The suspected trap, tested directly. `reconcile_deletions/3` runs
    # `delete_cached_event/3` for every ref in its `Enum.each`, and only then
    # calls `enqueue_mirror_withdrawals/2`. A resolver that reads the cache
    # inside the enqueue would therefore find nothing.
    #
    # Measured here: the enqueue works anyway, because the uid already travels
    # on the ref. The ordering is only a trap for a fix that defers uid
    # resolution to the enqueue.
    test "the withdrawal still enqueues, because the uid is on the ref not the cache",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      refs = [%{provider_event_id: "#{@master_id}_20260824T090000Z", uid: @series_uid}]

      assert :ok = Sync.reconcile_deletions(source, refs)

      assert [job] = jobs_for(@series_uid)
      assert job.args["operation"] == "delete"
      assert cached_rows(source) == []
    end

    # The same ordering seen from the resolver's side: once the row is gone,
    # `series_uid_for_master/2` can no longer answer. This is the constraint any
    # fix has to respect — resolve BEFORE the deletion, or from the batch.
    # The trap stated as the parent measured it live, and the test that would
    # LIE about it. Resolving the uid before the deletion succeeds; resolving it
    # after — which is where a downstream fix inside `enqueue_mirror_withdrawals`
    # would run — finds nothing. A fix tested only in the first order passes
    # while production silently fails to withdraw.
    test "resolving before the deletion succeeds and resolving after does not",
         %{source: source} do
      cache_the_series(source)

      before_delete =
        ProviderCalendarEventQueries.series_uid_for_master(source.id, @master_id)

      assert before_delete == {:ok, @series_uid}

      assert :ok =
               Sync.reconcile_deletions(source, [
                 %{provider_event_id: "#{@master_id}_20260907T090000Z", uid: @series_uid}
               ])

      after_delete =
        ProviderCalendarEventQueries.series_uid_for_master(source.id, @master_id)

      assert after_delete == {:error, :not_found}

      refute before_delete == after_delete,
             "the ordering is load-bearing: the resolver's answer changes across the delete"
    end

    # The synthesis fallback the parent verified live: for a Google-native
    # series the convention equals the cached uid, so a resolver that falls back
    # to synthesis still names the right mirror row after the cache is gone.
    test "synthesis matches the cached uid for a Google-native series",
         %{source: source} do
      row = cache_the_series(source)

      assert "#{@master_id}@google.com" == row.uid,
             "synthesis is only sound while this holds — a foreign-UID import breaks it"

      assert {:ok, ^row} = {:ok, row}
      assert row.uid == @series_uid
    end

    test "series_uid_for_master cannot answer after the row is deleted",
         %{source: source} do
      cache_the_series(source)

      assert {:ok, @series_uid} =
               ProviderCalendarEventQueries.series_uid_for_master(source.id, @master_id)

      assert :ok =
               Sync.reconcile_deletions(source, [
                 %{provider_event_id: "x", uid: @series_uid}
               ])

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.series_uid_for_master(source.id, @master_id)
    end
  end

  # ------------------------------------------------------------------
  # Hop G — what the current (unfixed) path actually does end to end
  # ------------------------------------------------------------------

  describe "hop G: what a deleted series does today, end to end" do
    # The live symptom, reproduced. The tombstones are misrouted to the active
    # path, where the normaliser builds them as tombstone CalendarEvents under
    # the SERIES uid; `upsert_cache/2` rejects them so no row changes, but
    # `post_commit_reconciliation/2` sees them and MovedOccurrence reads three
    # cancellations. The result is an :upsert carrying three EXDATEs — the
    # placeholder is rewritten, not withdrawn.
    test "an :upsert with three EXDATEs is enqueued instead of a :delete",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      assert :ok = sync(source, deletion_tombstones())

      jobs = jobs_for(@series_uid)
      assert length(jobs) == 1, "expected exactly one job, got #{length(jobs)}"

      job = hd(jobs)

      assert job.args["operation"] == "upsert",
             "the placeholder is rewritten rather than withdrawn"

      moved = job.args["moved"]
      assert length(moved) == 3, "expected 3 cancellations, got #{inspect(moved)}"
      assert Enum.all?(moved, &is_nil(&1["new_start"]))

      assert Enum.map(moved, & &1["original_start"]) == @occurrences
    end

    # A master fetch that genuinely FAILS — a rate limit, an expired token, a
    # network fault — still discards, and that is correct: nothing was learnt
    # about the series, so the placeholder is left alone for the sweep to retry.
    #
    # This test used to claim it reproduced the deleted-series symptom, on the
    # assumption that Google 404s a deleted master. **It does not.** Measured
    # against the live API, `get_event` for a deleted master returns a full
    # 19-key body with `recurrence` intact and `status: "cancelled"` — see
    # `test/support/captured/google_recurring_series.md` §5. So this branch is
    # never reached by a deletion, and a fix keyed on `:master_fetch_failed`
    # would have been a silent no-op.
    #
    # It is kept, renamed, as the guard for the transient-failure case it really
    # describes. The deleted-series path is driven with the captured cancelled
    # master in `SeriesDeletionWithdrawalTest`.
    test "a master fetch that fails discards, leaving the placeholder untouched",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror = mirror_the_series(link)

      assert :ok = sync(source, deletion_tombstones())

      assert [job] = jobs_for(@series_uid)
      assert job.args["operation"] == "upsert"

      # A transient fetch failure, NOT what a deleted series produces.
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:error, :not_found}
      end)

      assert {:discard, :series_master_unavailable} =
               perform_job(SyncLinkWriteBackWorker, job.args)

      # The mapping is untouched: still active, still naming a placeholder that
      # is still on the target calendar blocking availability.
      assert {:ok, reloaded} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, mirror.source_uid)

      assert reloaded.state == CalendarSyncMirrorSchema.state_active()
      assert reloaded.target_uid == mirror.target_uid
    end

    # And the cache row survives, so the source still looks alive to every
    # later reader — the sweep included.
    test "the series cache row survives the deletion sync", %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      assert :ok = sync(source, deletion_tombstones())

      assert [row] = cached_rows(source)
      assert row.status == "confirmed"
    end

    # The consequence of that surviving row: the reconcile sweep reads it as a
    # live, eligible source with an existing mapping and enqueues NOTHING to
    # withdraw. A deleted series is invisible to the backstop.
    test "the reconcile sweep does not withdraw the placeholder either",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      assert :ok = sync(source, deletion_tombstones())

      Repo.delete_all(Oban.Job)

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      deletes = Enum.filter(jobs_for(@series_uid), &(&1.args["operation"] == "delete"))

      assert deletes == [],
             "the sweep sees a cached, eligible source and never withdraws"
    end

    # The counterfactual: with the cache row gone, the sweep DOES withdraw. So
    # the sweep is a working backstop for a deletion that removes the row, and
    # is defeated only by the row surviving.
    test "with the cache row removed the sweep does withdraw", %{link: link} do
      mirror_the_series(link)

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert [job] = jobs_for(@series_uid)
      assert job.args["operation"] == "delete"
    end

    # And the hazard the task asked about: with the cache row gone but the
    # mapping still active, does the sweep RESURRECT the placeholder? It does
    # not — a mapping with no cached source is a withdrawal, never a rebuild.
    test "the sweep does not rebuild a placeholder whose source is uncached",
         %{link: link} do
      mirror_the_series(link)

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      upserts = Enum.filter(jobs_for(@series_uid), &(&1.args["operation"] == "upsert"))
      assert upserts == []
    end
  end
end
