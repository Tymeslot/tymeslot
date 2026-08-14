defmodule Tymeslot.Workers.SyncLinkReconcileSweepWorkerTest do
  @moduledoc """
  The cron fan-out: which links are due, and nothing else.

  Its whole contract is that it touches no provider and reads no calendar. It
  selects rows and inserts jobs, so a target that is down cannot slow it and a
  thousand links cannot make it a long-running job. No test here sets a Mox
  expectation, which makes `verify_on_exit!` the assertion that it stayed inside
  the database.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  # Mirrors `SyncLinkReconcileSweepWorker`'s own batch size, which is private
  # to that module. Stated here so the assertion below names the boundary it is
  # checking rather than a bare literal.
  @batch_size 50

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Workers.SyncLinkReconcileSweepWorker
  alias Tymeslot.Workers.SyncLinkReconcileWorker

  setup :verify_on_exit!

  defp swept_link_ids do
    [worker: SyncLinkReconcileWorker]
    |> all_enqueued()
    |> MapSet.new(& &1.args["sync_link_id"])
  end

  describe "perform/1" do
    test "enqueues one job per never-reconciled link" do
      %{link: link} = linked_pair()

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      assert swept_link_ids() == MapSet.new([link.id])
    end

    test "still sweeps a disabled link whose teardown left placeholders behind" do
      # Teardown disables the link *before* withdrawing, so a provider that
      # refused the delete leaves exactly this: disabled, with mappings in
      # `pending_delete` naming busy blocks still on someone's calendar.
      # Filtering those links out removed them from the retry their own teardown
      # depends on, stranding the orphan teardown exists to prevent.
      %{link: link} = linked_pair()
      {:ok, paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      mirror_for_link(paused, source_uid: "left-behind", state: "pending_delete")

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      # Membership rather than equality: the fixture's own enabled link is due
      # on its own account, and this is about the disabled one being reachable
      # at all.
      assert paused.id in swept_link_ids()
    end

    test "skips a disabled link" do
      %{link: link} = linked_pair()
      {:ok, _paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      refute_enqueued(worker: SyncLinkReconcileWorker)
    end

    test "skips a link reconciled inside the interval" do
      %{link: link} = linked_pair()

      {:ok, _fresh} =
        CalendarSyncLinkQueries.update(link, %{last_reconciled_at: DateTime.utc_now(:microsecond)})

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      refute_enqueued(worker: SyncLinkReconcileWorker)
    end

    test "enqueues a link whose last reconcile has aged out" do
      %{link: link} = linked_pair()

      stale = DateTime.add(DateTime.utc_now(:microsecond), -2, :hour)
      {:ok, _stale} = CalendarSyncLinkQueries.update(link, %{last_reconciled_at: stale})

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      assert swept_link_ids() == MapSet.new([link.id])
    end

    test "fans out across many links, staggering batches rather than sleeping" do
      # Two batches' worth plus one, so the stagger is observable at all: the
      # 51st link is the only job that lands in the second batch. Sleeping
      # between batches would hold the sweep's queue slot for the duration.
      user = insert(:user)
      source = insert(:calendar_integration, user: user, provider: "google")

      links =
        for _index <- 1..51 do
          target = insert(:calendar_integration, user: user, provider: "google")

          insert(:calendar_sync_link,
            user_id: user.id,
            source_integration_id: source.id,
            target_integration_id: target.id
          )
        end

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      jobs = all_enqueued(worker: SyncLinkReconcileWorker)
      assert length(jobs) == 51
      assert swept_link_ids() == MapSet.new(links, & &1.id)

      # Asserted by counting how the batches were scheduled rather than by
      # comparing against `utc_now()`. The second batch is scheduled one second
      # after the sweep, so a wall-clock assertion has under a second of margin
      # and fails whenever the machine stalls between the sweep and this line —
      # a GC pause or a loaded CI box is enough. The measured margin on an idle
      # machine was ~900ms, so that race was real rather than theoretical.
      #
      # Note the first batch carries no `scheduled_at` of its own, so Oban
      # defaults it to insertion time and its 50 rows spread over however long
      # the inserts took. Only the *second* batch is deliberately placed in the
      # future, and that placement is what this asserts.
      by_link = Map.new(jobs, &{&1.args["sync_link_id"], &1.scheduled_at})
      {first_batch_ids, second_batch_ids} = Enum.split(Enum.map(links, & &1.id), @batch_size)

      first_batch_latest =
        first_batch_ids |> Enum.map(&Map.fetch!(by_link, &1)) |> Enum.max(DateTime)

      assert [second_id] = second_batch_ids
      second_scheduled = Map.fetch!(by_link, second_id)

      assert DateTime.compare(second_scheduled, first_batch_latest) == :gt
    end

    test "reaches no provider" do
      # No Mox expectation is set: verify_on_exit! turns any provider call into
      # a failure. The sweep must decide what is due from rows alone.
      %{link: link} = linked_pair()

      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      assert swept_link_ids() == MapSet.new([link.id])
    end

    test "returns :ok when no link is configured" do
      assert :ok = perform_job(SyncLinkReconcileSweepWorker, %{})

      refute_enqueued(worker: SyncLinkReconcileWorker)
    end
  end
end
