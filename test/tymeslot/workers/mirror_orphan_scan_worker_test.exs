defmodule Tymeslot.Workers.MirrorOrphanScanWorkerTest do
  @moduledoc """
  The scheduled caller the orphan scan did not have.

  `SyncLink.OrphanScan` could always answer whether a placeholder was sitting on
  a calendar with nothing able to remove it; nothing in the deployed system
  could ask. These tests pin the two halves that close that gap — a sweep that
  fans out one job per organiser with links, and a per-user job that actually
  runs the scan — because a detector wired to nothing reports the same silence
  as a system with no orphans.

  No test here sets a Mox expectation. The scan reads two tables and calls no
  provider, and `verify_on_exit!` is what holds it to that: a daily pass over
  every organiser is only affordable while it stays inside the database.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Workers.MirrorOrphanScanWorker

  setup :verify_on_exit!

  # The suite runs the logger at `:warning`, and a clean scan reports at
  # `:info` deliberately — the empty case is quieter than a finding. The global
  # level has to be raised, not just the capture's: at `:warning` the call never
  # reaches the handler for `capture_log` to filter. Restored afterwards, and
  # the module is `async: false` so no concurrent test sees the raised level.
  defp at_info(fun) do
    original_level = Logger.level()
    Logger.configure(level: :info)

    log = capture_log([level: :info], fn -> assert :ok = fun.() end)

    Logger.configure(level: original_level)
    log
  end

  defp scanned_user_ids do
    [worker: MirrorOrphanScanWorker]
    |> all_enqueued()
    |> MapSet.new(& &1.args["user_id"])
  end

  describe "the sweep" do
    test "enqueues one scan per organiser holding a link" do
      %{user: user} = linked_pair()

      assert :ok = perform_job(MirrorOrphanScanWorker, %{})

      assert scanned_user_ids() == MapSet.new([user.id])
    end

    test "scans an organiser whose link is disabled" do
      # Teardown disables a link before withdrawing its placeholders, so a
      # provider that refused the delete leaves a disabled link whose busy
      # blocks are still on someone's calendar. Filtering on `enabled` would
      # skip exactly the organiser most likely to have an orphan.
      %{user: user, link: link} = linked_pair()
      {:ok, _paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      assert :ok = perform_job(MirrorOrphanScanWorker, %{})

      assert scanned_user_ids() == MapSet.new([user.id])
    end

    test "enqueues one job per organiser rather than one per link" do
      %{user: user} = fixture = linked_pair()
      {_third, _second_link} = extra_target_link(fixture)

      assert :ok = perform_job(MirrorOrphanScanWorker, %{})

      assert length(all_enqueued(worker: MirrorOrphanScanWorker)) == 1
      assert scanned_user_ids() == MapSet.new([user.id])
    end

    test "ignores an organiser with no links" do
      insert(:user)

      assert :ok = perform_job(MirrorOrphanScanWorker, %{})

      refute_enqueued(worker: MirrorOrphanScanWorker)
    end

    test "reaches no provider" do
      %{user: user} = linked_pair()

      assert :ok = perform_job(MirrorOrphanScanWorker, %{})

      assert scanned_user_ids() == MapSet.new([user.id])
    end
  end

  describe "the per-user scan" do
    test "reports a placeholder no mapping row claims" do
      # The state the whole feature exists to surface: the placeholder is on the
      # target and cached, and nothing records where it is. Asserted through the
      # log because reporting *is* the output — the scan deliberately writes no
      # row and repairs nothing.
      %{user: user, target: target, link: link} = linked_pair()
      uid = Engine.target_uid_for(link.id, "source-uid-1")

      insert(:provider_calendar_event,
        calendar_integration: target,
        uid: uid,
        summary: "Busy",
        provider: "google"
      )

      log =
        capture_log(fn ->
          assert :ok = perform_job(MirrorOrphanScanWorker, %{"user_id" => user.id})
        end)

      assert log =~ "Mirror orphan scan found unclaimed placeholders"
    end

    test "records that a clean scan ran, rather than staying silent" do
      # A scan that found nothing and a scan that never ran look identical
      # afterwards, and telling them apart is the point of running this before
      # any repair is written.
      %{user: user} = linked_pair()

      log = at_info(fn -> perform_job(MirrorOrphanScanWorker, %{"user_id" => user.id}) end)

      assert log =~ "Mirror orphan scan found nothing"
    end

    test "a claimed placeholder is not reported" do
      %{user: user, target: target, link: link} = linked_pair()
      uid = Engine.target_uid_for(link.id, "source-uid-1")

      insert(:provider_calendar_event,
        calendar_integration: target,
        uid: uid,
        summary: "Busy",
        provider: "google"
      )

      mirror_for_link(link, source_uid: "source-uid-1", target_uid: uid)

      log = at_info(fn -> perform_job(MirrorOrphanScanWorker, %{"user_id" => user.id}) end)

      assert log =~ "Mirror orphan scan found nothing"
    end
  end
end
