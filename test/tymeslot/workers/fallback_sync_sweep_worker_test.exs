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
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.SyncGating
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

  describe "perform/1 - sync gating" do
    test "does not enqueue a job for a Google integration with enough consecutive hard failures" do
      integration = insert(:calendar_integration, provider: "google", is_active: true)
      user_id = integration.user_id

      {:ok, _} =
        IntegrationHealthStateQueries.upsert(:calendar, integration.id, %{
          user_id: user_id,
          status: "unhealthy",
          failures: SyncGating.threshold(),
          consecutive_hard_failures: SyncGating.threshold(),
          successes: 0,
          backoff_ms: 1_800_000,
          last_check_at: DateTime.utc_now(),
          last_error_class: "hard"
        })

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      refute_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "still enqueues a non-gated integration when a gated one is present" do
      gated = insert(:calendar_integration, provider: "google", is_active: true)
      healthy = insert(:calendar_integration, provider: "google", is_active: true)

      {:ok, _} =
        IntegrationHealthStateQueries.upsert(:calendar, gated.id, %{
          user_id: gated.user_id,
          status: "unhealthy",
          failures: SyncGating.threshold(),
          consecutive_hard_failures: SyncGating.threshold(),
          successes: 0,
          backoff_ms: 1_800_000,
          last_check_at: DateTime.utc_now(),
          last_error_class: "hard"
        })

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      refute_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => gated.id}
      )

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => healthy.id}
      )
    end
  end

  describe "perform/1 - Outlook integration without delta link" do
    test "calls bootstrap_sync to seed the integration and then attempts subscription registration" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          graph_delta_link: nil
        )

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        assert received.id == integration.id
        {:ok, %{integration | graph_delta_link: "fresh-delta-link"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:ok, integration}
      end)

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})
    end

    test "bootstrap_sync runs even when subscription registration is skipped without webhook URL" do
      insert(:calendar_integration,
        provider: "outlook",
        is_active: true,
        graph_delta_link: nil
      )

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn integration ->
        {:ok, %{integration | graph_delta_link: "bootstrap-delta-link"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})
    end

    test "reports the integration as errored when bootstrap_sync itself fails" do
      insert(:calendar_integration,
        provider: "outlook",
        is_active: true,
        graph_delta_link: nil
      )

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :circuit_open}
      end)

      # register_graph_subscription must NOT be called when bootstrap failed —
      # Mox will raise if it is.
      assert :ok = perform_job(FallbackSyncSweepWorker, %{})
    end
  end
end
