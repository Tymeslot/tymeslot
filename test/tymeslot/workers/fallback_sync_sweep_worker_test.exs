defmodule Tymeslot.Workers.FallbackSyncSweepWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory
  require Logger

  alias Ecto.Query
  alias Tymeslot.Workers.FallbackSyncSweepWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  describe "perform/1 - no active integrations" do
    test "returns :ok when there are no active integrations" do
      assert :ok = perform_job(FallbackSyncSweepWorker, %{})
    end
  end

  describe "perform/1 - active Google integration" do
    test "enqueues a SyncGoogleCalendarWorker job for each active Google integration" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          is_active: true
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "enqueues jobs for multiple active Google integrations" do
      integration1 = insert(:calendar_integration, provider: "google", is_active: true)
      integration2 = insert(:calendar_integration, provider: "google", is_active: true)

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration1.id}
      )

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration2.id}
      )
    end
  end

  describe "perform/1 - active CalDAV integration" do
    test "enqueues a SyncCalDavCalendarWorker job for each active CalDAV integration" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "perform/1 - active Radicale integration" do
    test "enqueues a SyncCalDavCalendarWorker job for each active Radicale integration" do
      integration =
        insert(:calendar_integration,
          provider: "radicale",
          is_active: true
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "perform/1 - active Nextcloud integration" do
    test "enqueues a SyncCalDavCalendarWorker job for each active Nextcloud integration" do
      integration =
        insert(:calendar_integration,
          provider: "nextcloud",
          is_active: true
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "perform/1 - active Zimbra integration" do
    test "enqueues a SyncCalDavCalendarWorker job for each active Zimbra integration" do
      integration =
        insert(:calendar_integration,
          provider: "zimbra",
          is_active: true
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "perform/1 - inactive integration" do
    test "does not enqueue any job for an inactive integration" do
      insert(:calendar_integration, provider: "google", is_active: false)

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end
  end

  describe "perform/1 - periodic forced full fetch for CalDAV" do
    test "enqueues force_full_fetch job for CalDAV integration with last_full_sync_at = nil" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          last_full_sync_at: nil
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{
          "calendar_integration_id" => integration.id,
          "force_full_fetch" => true
        }
      )
    end

    test "enqueues force_full_fetch job when last_full_sync_at is older than 12 hours" do
      stale = DateTime.add(DateTime.utc_now(), -13 * 3600, :second)

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          last_full_sync_at: stale
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{
          "calendar_integration_id" => integration.id,
          "force_full_fetch" => true
        }
      )
    end

    test "does not enqueue force_full_fetch job when last_full_sync_at is within 12 hours" do
      fresh = DateTime.add(DateTime.utc_now(), -3600, :second)

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          last_full_sync_at: fresh
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      refute_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{
          "calendar_integration_id" => integration.id,
          "force_full_fetch" => true
        }
      )
    end

    test "schedules force_full_fetch jobs with a future scheduled_at within 15 minutes" do
      insert(:calendar_integration,
        provider: "caldav",
        is_active: true,
        last_full_sync_at: nil
      )

      before_enqueue = DateTime.utc_now()

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      job =
        Oban.Job
        |> Query.where([j], j.worker == "Tymeslot.Workers.SyncCalDavCalendarWorker")
        |> Query.where([j], fragment("?->>'force_full_fetch' = 'true'", j.args))
        |> Repo.one!()

      assert DateTime.after?(job.scheduled_at, before_enqueue)
      assert DateTime.before?(job.scheduled_at, DateTime.add(before_enqueue, 900 + 5, :second))
    end

    test "applies to all CalDAV-based providers, not only provider=caldav" do
      radicale =
        insert(:calendar_integration,
          provider: "radicale",
          is_active: true,
          last_full_sync_at: nil
        )

      nextcloud =
        insert(:calendar_integration,
          provider: "nextcloud",
          is_active: true,
          last_full_sync_at: nil
        )

      zimbra =
        insert(:calendar_integration,
          provider: "zimbra",
          is_active: true,
          last_full_sync_at: nil
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      for integration <- [radicale, nextcloud, zimbra] do
        assert_enqueued(
          worker: SyncCalDavCalendarWorker,
          args: %{
            "calendar_integration_id" => integration.id,
            "force_full_fetch" => true
          }
        )
      end
    end

    test "when both normal and forced are due, forced wins the unique slot" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          last_full_sync_at: nil,
          last_external_sync_at: nil
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      jobs =
        Oban.Job
        |> Query.where([j], j.worker == "Tymeslot.Workers.SyncCalDavCalendarWorker")
        |> Query.where(
          [j],
          fragment("(?->>'calendar_integration_id')::int = ?", j.args, ^integration.id)
        )
        |> Repo.all()

      assert length(jobs) == 1
      [job] = jobs
      assert job.args["force_full_fetch"] == true
    end

    test "deduped normal-sync conflict is not counted in caldav_scheduled" do
      # Integration with last_full_sync_at nil (forced full due) and
      # last_external_sync_at nil (normal CalDAV sync also due). The forced job
      # wins the Oban unique slot; the subsequent normal-sync enqueue returns a
      # conflict from Oban and must NOT be counted as a scheduled job.
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          last_full_sync_at: nil,
          last_external_sync_at: nil
        )

      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log([level: :info], fn ->
          assert :ok = perform_job(FallbackSyncSweepWorker, %{})
        end)

      Logger.configure(level: original_level)

      # The completion log must be emitted.
      assert log =~ "FallbackSyncSweep complete"

      # Exactly one job exists in the queue for this integration — the forced
      # full-fetch. The normal-sync enqueue was deduped (conflict) by Oban and
      # produced no additional row.
      jobs =
        Oban.Job
        |> Query.where([j], j.worker == "Tymeslot.Workers.SyncCalDavCalendarWorker")
        |> Query.where(
          [j],
          fragment("(?->>'calendar_integration_id')::int = ?", j.args, ^integration.id)
        )
        |> Repo.all()

      assert length(jobs) == 1
      assert hd(jobs).args["force_full_fetch"] == true
    end
  end

  describe "perform/1 - Outlook integration without delta link" do
    test "calls register_graph_subscription to seed the integration" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          graph_delta_link: nil
        )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:ok, integration}
      end)

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})
    end

    test "returns :ok and skips gracefully when WEBHOOK_BASE_URL is not configured" do
      insert(:calendar_integration,
        provider: "outlook",
        is_active: true,
        graph_delta_link: nil
      )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})
    end
  end
end
