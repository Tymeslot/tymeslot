defmodule Tymeslot.Workers.SyncLinkReconcileWorkerTest do
  @moduledoc """
  The safety net, and the one way it could do more harm than the drift it fixes.

  Reconciliation re-diffs one link's whole state: every eligible source event in
  the sync window against every mapping row, enqueueing an upsert for what is
  missing or stale and a delete for what no longer has a source. Because it
  enqueues rather than writes, no test here sets a Mox expectation — and
  `verify_on_exit!` therefore fails any of them that reaches a provider.

  The dangerous case has its own describe block. A windowed re-diff sees only
  part of the source calendar, so "not in the events I read" and "gone from the
  calendar" are different statements; conflating them deletes every mirror
  outside the window on the first sweep, silently and at once. The window is
  wide (a year either side, matching what the cache is populated with), which
  makes the bug rare enough to survive review and catastrophic when it fires.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Workers.SyncLinkReconcileWorker
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  defp cached_event(source, attrs) do
    start_at = DateTime.add(DateTime.utc_now(:microsecond), 3, :day)

    defaults = [
      calendar_integration: source,
      provider: source.provider,
      all_day: false,
      start_at: start_at,
      end_at: DateTime.add(start_at, 3600, :second)
    ]

    insert(:provider_calendar_event, Keyword.merge(defaults, attrs))
  end

  defp operations do
    [worker: SyncLinkWriteBackWorker]
    |> all_enqueued()
    |> MapSet.new(&{&1.args["sync_link_id"], &1.args["source_uid"], &1.args["operation"]})
  end

  describe "perform/1 — the diff" do
    test "an eligible source with no mapping is enqueued for upsert", %{
      source: source,
      link: link
    } do
      cached_event(source, uid: "unmapped-uid")

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert operations() == MapSet.new([{link.id, "unmapped-uid", "upsert"}])
    end

    test "a mapping whose source is gone from the window is enqueued for delete", %{
      link: link
    } do
      # No cached event at all: the source was deleted on the provider and the
      # inbound sync removed it from the cache, but the mirror write never ran.
      mirror_for_link(link, source_uid: "vanished-uid")

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert operations() == MapSet.new([{link.id, "vanished-uid", "delete"}])
    end

    test "a source that has stopped being eligible is enqueued for delete", %{
      source: source,
      link: link
    } do
      cached_event(source, uid: "cancelled-uid", status: "cancelled")
      mirror_for_link(link, source_uid: "cancelled-uid")

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert operations() == MapSet.new([{link.id, "cancelled-uid", "delete"}])
    end

    test "a source unchanged since its mapping was written is left alone", %{
      source: source,
      link: link
    } do
      updated_at = ~U[2026-07-01 09:00:00.000000Z]

      cached_event(source, uid: "steady-uid", provider_updated_at: updated_at)
      mirror_for_link(link, source_uid: "steady-uid", source_updated_at: updated_at)

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "a source changed since its mapping was written is enqueued for upsert", %{
      source: source,
      link: link
    } do
      cached_event(source, uid: "moved-uid", provider_updated_at: ~U[2026-07-02 09:00:00.000000Z])

      mirror_for_link(link,
        source_uid: "moved-uid",
        source_updated_at: ~U[2026-07-01 09:00:00.000000Z]
      )

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert operations() == MapSet.new([{link.id, "moved-uid", "upsert"}])
    end

    test "a mapping stuck in pending_delete has its delete retried", %{
      source: source,
      link: link
    } do
      # The source is still cached and still eligible. Only the mapping's state
      # says a teardown was started and never confirmed by the provider.
      cached_event(source, uid: "stuck-uid")
      mirror_for_link(link, source_uid: "stuck-uid", state: "pending_delete")

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert operations() == MapSet.new([{link.id, "stuck-uid", "delete"}])
    end

    test "an event that is itself a mirror is never a source", %{
      source: source,
      link: link,
      target: target
    } do
      # The reverse link's placeholder, sitting on this link's source calendar.
      reverse =
        insert(:calendar_sync_link,
          user_id: link.user_id,
          source_integration_id: target.id,
          target_integration_id: source.id
        )

      mirror_uid = Engine.target_uid_for(reverse.id, "far-side-uid")

      mirror_for_link(reverse, source_uid: "far-side-uid", target_uid: mirror_uid)
      cached_event(source, uid: mirror_uid)

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "converges a deliberately desynchronised link in one pass", %{
      source: source,
      link: link
    } do
      # Three kinds of drift at once, which is what a missed webhook window
      # actually looks like.
      cached_event(source, uid: "created-uid")

      mirror_for_link(link, source_uid: "deleted-uid")

      cached_event(source,
        uid: "changed-uid",
        provider_updated_at: ~U[2026-07-02 09:00:00.000000Z]
      )

      mirror_for_link(link,
        source_uid: "changed-uid",
        source_updated_at: ~U[2026-07-01 09:00:00.000000Z]
      )

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert operations() ==
               MapSet.new([
                 {link.id, "created-uid", "upsert"},
                 {link.id, "deleted-uid", "delete"},
                 {link.id, "changed-uid", "upsert"}
               ])
    end

    test "stamps last_reconciled_at on completion", %{link: link} do
      assert is_nil(link.last_reconciled_at)

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert {:ok, reloaded} = CalendarSyncLinkQueries.get(link.id)
      assert %DateTime{} = reloaded.last_reconciled_at
    end
  end

  describe "perform/1 — the window" do
    test "a mapping for an event outside the window is not deleted", %{
      source: source,
      link: link
    } do
      # A meeting three years out. It is genuinely on the source calendar and
      # genuinely mirrored — the cache holds it because the provider returned it
      # once — but it falls outside the range the re-diff reads. Treating "not
      # in the events I read" as "gone from the calendar" tears this mirror down
      # and every other one like it, on the first sweep, with no way back.
      far_future = DateTime.add(DateTime.utc_now(:microsecond), 3 * 365, :day)

      cached_event(source,
        uid: "far-future-uid",
        start_at: far_future,
        end_at: DateTime.add(far_future, 3600, :second)
      )

      mirror_for_link(link, source_uid: "far-future-uid")

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "a mapping whose source is gone entirely is still deleted", %{link: link} do
      # The discriminating case for the one above: scoping mappings to the
      # window must not become "never delete anything". No cache row exists for
      # this UID at any date, so the source really is gone.
      mirror_for_link(link, source_uid: "truly-gone-uid")

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert operations() == MapSet.new([{link.id, "truly-gone-uid", "delete"}])
    end
  end

  describe "perform/1 — discards" do
    test "a link that no longer exists is discarded", %{link: link} do
      {:ok, _deleted} = CalendarSyncLinkQueries.delete(link)

      assert {:discard, :link_not_found} =
               perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})
    end

    test "a paused link is discarded, and nothing is enqueued", %{source: source, link: link} do
      cached_event(source, uid: "unmapped-uid")
      {:ok, _paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      assert {:discard, :link_disabled} =
               perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end
  end

  describe "perform/1 — after a resume" do
    # Resuming a link enqueues nothing — `SyncLink.toggle_enabled/3` flips the
    # row and stops — so everything that changed on the source calendar during
    # the pause is repaired here or nowhere. This is the other end of that
    # contract, and the reason the resume is allowed to be as quiet as it is.
    #
    # Three kinds of drift accumulate across a pause and the sweep must answer
    # all three: a source created while paused has no placeholder, one edited
    # while paused has a stale one, and one deleted while paused has a
    # placeholder still blocking time for a meeting that is not happening.
    test "repairs everything that changed on the source while the link was paused", %{
      source: source,
      link: link
    } do
      {:ok, paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      # Created during the pause: cached, eligible, and never mirrored, because
      # the write-back the push path enqueued was discarded as `:link_disabled`.
      cached_event(source, uid: "created-while-paused")

      # Edited during the pause: the mapping is older than the source event.
      cached_event(source,
        uid: "edited-while-paused",
        provider_updated_at: ~U[2026-07-02 09:00:00.000000Z]
      )

      mirror_for_link(paused,
        source_uid: "edited-while-paused",
        source_updated_at: ~U[2026-07-01 09:00:00.000000Z]
      )

      # Deleted during the pause: the mapping outlived its source entirely.
      mirror_for_link(paused, source_uid: "deleted-while-paused")

      # While still paused, none of it is the sweep's business — that is what
      # pausing means, and the discard is asserted rather than assumed so the
      # repair below is demonstrably the resume's doing.
      assert {:discard, :link_disabled} =
               perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => paused.id})

      refute_enqueued(worker: SyncLinkWriteBackWorker)

      {:ok, _resumed} = CalendarSyncLinkQueries.update(paused, %{enabled: true})

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      assert operations() ==
               MapSet.new([
                 {link.id, "created-while-paused", "upsert"},
                 {link.id, "edited-while-paused", "upsert"},
                 {link.id, "deleted-while-paused", "delete"}
               ])
    end

    # The placeholders a pause deliberately left alone are not rewritten on the
    # way back. A pause is not a teardown — the busy blocks stayed on the target
    # and stayed correct — so a source untouched across the pause is untouched
    # after it, and a resume costs no provider write for a calendar that already
    # says the right thing.
    test "leaves a placeholder whose source did not change during the pause alone", %{
      source: source,
      link: link
    } do
      updated_at = ~U[2026-07-01 09:00:00.000000Z]

      cached_event(source, uid: "steady-uid", provider_updated_at: updated_at)
      mirror_for_link(link, source_uid: "steady-uid", source_updated_at: updated_at)

      {:ok, paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})
      {:ok, _resumed} = CalendarSyncLinkQueries.update(paused, %{enabled: true})

      assert :ok = perform_job(SyncLinkReconcileWorker, %{"sync_link_id" => link.id})

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end
  end
end
