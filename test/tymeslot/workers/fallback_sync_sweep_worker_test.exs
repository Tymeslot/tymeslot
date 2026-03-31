defmodule Tymeslot.Workers.FallbackSyncSweepWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

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
