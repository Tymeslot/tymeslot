defmodule Tymeslot.Integrations.Calendar.SyncLink.SyncHookTest do
  @moduledoc """
  Where mirroring joins the inbound pipeline.

  `Sync.post_commit_reconciliation/2` is the seam: it runs outside any
  transaction, after the cache write has committed, alongside the availability
  invalidation and the PubSub broadcast that are already there. What it must do
  is *enqueue*, never write. A provider call here would put a second calendar's
  latency inside the first calendar's sync, so a slow or failing target could
  stall an inbound sync that has nothing to do with it — which is why these
  tests assert on the job queue and set no provider expectation at all.

  The loop-prevention assertion is the end-to-end counterpart of the one in
  `EligibilityTest`: a placeholder arriving back through an inbound sync must
  enqueue nothing, because a mirror is a leaf.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  defp event(integration, attrs \\ %{}) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: "source-uid-1",
          calendar_integration_id: integration.id,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "source-pid-1",
          summary: "Board meeting",
          all_day: false,
          start_at: ~U[2026-07-03 09:00:00Z],
          end_at: ~U[2026-07-03 10:00:00Z],
          synced_at: ~U[2026-07-01 00:00:00Z]
        },
        attrs
      )
    )
  end

  describe "post_commit_reconciliation/2 enqueues mirror writes" do
    test "one job per enabled link whose source is this integration", %{
      source: source,
      link: link
    } do
      :ok = Sync.post_commit_reconciliation(source, [event(source)])

      assert_enqueued(
        worker: SyncLinkWriteBackWorker,
        args: %{
          "sync_link_id" => link.id,
          "source_uid" => "source-uid-1",
          "operation" => "upsert"
        }
      )
    end

    test "a second link on the same source gets its own job", %{link: link} = ctx do
      {_second_target, second} = extra_target_link(ctx)

      :ok = Sync.post_commit_reconciliation(ctx.source, [event(ctx.source)])

      enqueued = all_enqueued(worker: SyncLinkWriteBackWorker)

      assert MapSet.new(enqueued, & &1.args["sync_link_id"]) ==
               MapSet.new([link.id, second.id])
    end

    test "an integration that is nobody's source enqueues nothing", %{target: target} do
      :ok = Sync.post_commit_reconciliation(target, [event(target)])

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "a paused link enqueues nothing", %{source: source, link: link} do
      {:ok, _paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      :ok = Sync.post_commit_reconciliation(source, [event(source)])

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "no provider call is made from the sync path", %{source: source} do
      # No Mox expectation is set: verify_on_exit! fails the test if the sync
      # path reaches a provider rather than enqueueing.
      :ok = Sync.post_commit_reconciliation(source, [event(source)])

      assert_enqueued(worker: SyncLinkWriteBackWorker)
    end
  end

  describe "post_commit_reconciliation/2 loop prevention" do
    test "a placeholder arriving back through an inbound sync spawns nothing",
         %{target: target, link: forward} = ctx do
      # The pair is bidirectional. `target` is now also a source, and the
      # placeholder the forward link wrote onto it is arriving on target's own
      # inbound sync.
      _reverse = reverse_link(ctx)

      mirror_uid = Engine.target_uid_for(forward.id, "source-uid-1")
      mirror_for_link(forward, source_uid: "source-uid-1", target_uid: mirror_uid)

      :ok =
        Sync.post_commit_reconciliation(target, [
          event(target, %{uid: mirror_uid, summary: "Busy", provider_event_id: "target-pid-1"})
        ])

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "an ordinary event on the same calendar as a mirror still enqueues",
         %{target: target, link: forward} = ctx do
      reverse = reverse_link(ctx)

      mirror_uid = Engine.target_uid_for(forward.id, "source-uid-1")
      mirror_for_link(forward, source_uid: "source-uid-1", target_uid: mirror_uid)

      :ok =
        Sync.post_commit_reconciliation(target, [
          event(target, %{uid: mirror_uid, provider_event_id: "target-pid-1"}),
          event(target, %{uid: "genuine-uid", provider_event_id: "target-pid-2"})
        ])

      assert [job] = all_enqueued(worker: SyncLinkWriteBackWorker)
      assert job.args["sync_link_id"] == reverse.id
      assert job.args["source_uid"] == "genuine-uid"
    end
  end

  describe "post_commit_reconciliation/2 fan-out" do
    test "one source event on three links produces three jobs",
         %{source: source, link: first} = ctx do
      {_second_target, second} = extra_target_link(ctx)
      {_third_target, third} = extra_target_link(ctx)

      :ok = Sync.post_commit_reconciliation(source, [event(source)])

      jobs = all_enqueued(worker: SyncLinkWriteBackWorker)

      assert MapSet.new(jobs, &{&1.args["sync_link_id"], &1.args["source_uid"]}) ==
               MapSet.new([
                 {first.id, "source-uid-1"},
                 {second.id, "source-uid-1"},
                 {third.id, "source-uid-1"}
               ])
    end

    test "fan-out stops at the links that are enabled", %{source: source, link: first} = ctx do
      {_second_target, second} = extra_target_link(ctx)
      {:ok, _paused} = CalendarSyncLinkQueries.update(second, %{enabled: false})

      :ok = Sync.post_commit_reconciliation(source, [event(source)])

      assert [job] = all_enqueued(worker: SyncLinkWriteBackWorker)
      assert job.args["sync_link_id"] == first.id
    end
  end

  describe "post_commit_reconciliation/2 paired-link convergence" do
    # Loop prevention — a mirror never spawning a mirror — is asserted above.
    # This is the other half of a bidirectional pair's correctness, and it is a
    # different claim: with both rows in place, a genuine change on *either*
    # calendar still reaches the other. A loop-prevention rule that is too eager
    # passes every test in that block and fails every test in this one.
    test "a change on the source reaches the target", %{source: source, link: forward} = ctx do
      _reverse = reverse_link(ctx)

      :ok = Sync.post_commit_reconciliation(source, [event(source, %{uid: "on-source"})])

      assert [job] = all_enqueued(worker: SyncLinkWriteBackWorker)
      assert job.args["sync_link_id"] == forward.id
      assert job.args["source_uid"] == "on-source"
    end

    test "a change on the target reaches the source", %{target: target} = ctx do
      reverse = reverse_link(ctx)

      :ok =
        Sync.post_commit_reconciliation(target, [
          event(target, %{uid: "on-target", provider_event_id: "target-pid-9"})
        ])

      assert [job] = all_enqueued(worker: SyncLinkWriteBackWorker)
      assert job.args["sync_link_id"] == reverse.id
      assert job.args["source_uid"] == "on-target"
    end

    test "both directions converge in the same sync round",
         %{source: source, target: target} =
           ctx do
      forward = ctx.link
      reverse = reverse_link(ctx)

      :ok = Sync.post_commit_reconciliation(source, [event(source, %{uid: "on-source"})])

      :ok =
        Sync.post_commit_reconciliation(target, [
          event(target, %{uid: "on-target", provider_event_id: "target-pid-9"})
        ])

      jobs = all_enqueued(worker: SyncLinkWriteBackWorker)

      assert MapSet.new(jobs, &{&1.args["sync_link_id"], &1.args["source_uid"]}) ==
               MapSet.new([
                 {forward.id, "on-source"},
                 {reverse.id, "on-target"}
               ])
    end
  end

  describe "post_commit_reconciliation/2 skips ineligible sources" do
    # Recurrence is the one scoping rule this gate cannot apply, and the reason
    # is structural rather than a relaxation: whether a recurring source may be
    # mirrored depends on the *target*, and this filter runs once for a batch
    # shared across every link out of the calendar. So the job is enqueued for
    # each link and the worker — which holds one link and can ask its target —
    # decides. A Google target mirrors the series; an Outlook one discards, or
    # withdraws a placeholder that has gone stale.
    test "a recurring event enqueues: only the worker knows the link's target", %{
      source: source,
      link: link
    } do
      :ok =
        Sync.post_commit_reconciliation(source, [
          event(source, %{recurrence_rule: "FREQ=WEEKLY;COUNT=4"})
        ])

      assert_enqueued(
        worker: SyncLinkWriteBackWorker,
        args: %{
          "sync_link_id" => link.id,
          "source_uid" => "source-uid-1",
          "operation" => "upsert"
        }
      )
    end

    # An event that stops blocking time is not the same as one that was never
    # eligible: it may already have a placeholder holding a slot the organiser
    # has just freed. The job carries `upsert` regardless — the worker decides
    # between writing and withdrawing, because only it knows whether a mapping
    # exists — and its discard when there is nothing to withdraw is what keeps
    # this cheap.
    test "a transparent event enqueues, so an existing placeholder is withdrawn", %{
      source: source,
      link: link
    } do
      :ok =
        Sync.post_commit_reconciliation(source, [event(source, %{transparency: :transparent})])

      assert_enqueued(
        worker: SyncLinkWriteBackWorker,
        args: %{
          "sync_link_id" => link.id,
          "source_uid" => "source-uid-1",
          "operation" => "upsert"
        }
      )
    end

    test "a cancelled event enqueues for the same reason", %{source: source, link: link} do
      :ok = Sync.post_commit_reconciliation(source, [event(source, %{status: :cancelled})])

      assert_enqueued(
        worker: SyncLinkWriteBackWorker,
        args: %{
          "sync_link_id" => link.id,
          "source_uid" => "source-uid-1",
          "operation" => "upsert"
        }
      )
    end
  end

  describe "reconcile_deletions/3 withdraws the mirror" do
    # The deletion counterpart of the enqueue above, and the half that was
    # missing: a source event vanishing from its calendar left its placeholder
    # standing on the target until the reconcile sweep noticed, up to half an
    # hour later. `reconcile_deletions/3` is the one primitive every provider's
    # deletion path funnels through — Google's cancelled events, Outlook's
    # delta `@removed`, CalDAV's absent uids — so hooking it here covers all of
    # them at once rather than three times over.
    test "a deleted source event enqueues a delete for its link", %{
      source: source,
      link: link
    } do
      :ok =
        Sync.reconcile_deletions(source, [
          %{provider_event_id: "source-pid-1", uid: "source-uid-1"}
        ])

      assert_enqueued(
        worker: SyncLinkWriteBackWorker,
        args: %{
          "sync_link_id" => link.id,
          "source_uid" => "source-uid-1",
          "operation" => "delete"
        }
      )
    end

    test "each enabled link gets its own withdrawal", %{source: source, link: first} = ctx do
      {_second_target, second} = extra_target_link(ctx)

      :ok =
        Sync.reconcile_deletions(source, [
          %{provider_event_id: "source-pid-1", uid: "source-uid-1"}
        ])

      jobs = all_enqueued(worker: SyncLinkWriteBackWorker)

      assert MapSet.new(jobs, &{&1.args["sync_link_id"], &1.args["operation"]}) ==
               MapSet.new([{first.id, "delete"}, {second.id, "delete"}])
    end

    test "a paused link is not asked to withdraw", %{source: source, link: link} do
      {:ok, _paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      :ok =
        Sync.reconcile_deletions(source, [
          %{provider_event_id: "source-pid-1", uid: "source-uid-1"}
        ])

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "a deletion on a calendar that is nobody's source enqueues nothing", %{target: target} do
      :ok =
        Sync.reconcile_deletions(target, [
          %{provider_event_id: "target-pid-1", uid: "target-uid-1"}
        ])

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    # A source that was never mirrored has no mapping row, and the enqueue does
    # not check for one — the engine's `unmirror/3` answers `:ok` for exactly
    # this case. The job is cheap and the alternative, a lookup per deleted
    # event on every sync, is not.
    test "a source that was never mirrored still enqueues cleanly", %{
      source: source,
      link: link
    } do
      assert :ok ==
               Sync.reconcile_deletions(source, [
                 %{provider_event_id: "never-seen-pid", uid: "never-mirrored-uid"}
               ])

      assert_enqueued(
        worker: SyncLinkWriteBackWorker,
        args: %{
          "sync_link_id" => link.id,
          "source_uid" => "never-mirrored-uid",
          "operation" => "delete"
        }
      )
    end

    # Outlook's delta reports a removal with no iCalUID at all. There is no
    # source uid to withdraw by, so nothing can be enqueued — and guessing one
    # from the provider id would address a placeholder that was never written
    # under that name.
    test "a deletion carrying no uid enqueues nothing", %{source: source} do
      :ok = Sync.reconcile_deletions(source, [%{provider_event_id: "source-pid-1", uid: nil}])

      refute_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "no provider call is made from the deletion path", %{source: source} do
      # No Mox expectation is set: verify_on_exit! fails the test if the
      # deletion path reaches a provider instead of enqueueing. A slow target
      # must never sit inside an inbound sync of a different calendar.
      :ok =
        Sync.reconcile_deletions(source, [
          %{provider_event_id: "source-pid-1", uid: "source-uid-1"}
        ])

      assert_enqueued(worker: SyncLinkWriteBackWorker)
    end
  end
end
