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

  describe "post_commit_reconciliation/2 skips ineligible sources" do
    test "a recurring event enqueues nothing", %{source: source} do
      :ok =
        Sync.post_commit_reconciliation(source, [
          event(source, %{recurrence_rule: "FREQ=WEEKLY;COUNT=4"})
        ])

      refute_enqueued(worker: SyncLinkWriteBackWorker)
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
end
