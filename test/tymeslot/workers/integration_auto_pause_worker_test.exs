defmodule Tymeslot.Workers.IntegrationAutoPauseWorkerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations
  @moduletag :workers

  import Tymeslot.TestFixtures
  import Tymeslot.WorkerTestHelpers, only: [insert_unhealthy_health_row: 4]

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.IntegrationAutoPauseWorker

  setup do
    user = create_user_fixture()
    %{user: user}
  end

  describe "perform/1 — prolonged unhealthy trigger" do
    test "deactivates calendar integrations unhealthy for 14+ days and schedules email", %{
      user: user
    } do
      integration = insert(:calendar_integration, user: user, is_active: true)

      old_unhealthy = DateTime.add(DateTime.utc_now(), -15 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :calendar, integration.id,
        became_unhealthy_at: old_unhealthy,
        consecutive_hard_failures: 5
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      {:ok, paused} = CalendarIntegrationQueries.get(integration.id)
      assert paused.is_active == false

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_paused_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "calendar"
        }
      )
    end

    test "deactivates video integrations unhealthy for 14+ days", %{user: user} do
      integration = insert(:video_integration, user: user, is_active: true)

      old_unhealthy = DateTime.add(DateTime.utc_now(), -15 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :video, integration.id,
        became_unhealthy_at: old_unhealthy,
        consecutive_hard_failures: 5
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      {:ok, paused} = VideoIntegrationQueries.get(integration.id)
      assert paused.is_active == false
    end

    test "leaves integrations unhealthy for less than 14 days alone", %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      recent = DateTime.add(DateTime.utc_now(), -10 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :calendar, integration.id,
        became_unhealthy_at: recent,
        consecutive_hard_failures: 5
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      {:ok, still_active} = CalendarIntegrationQueries.get(integration.id)
      assert still_active.is_active == true

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_integration_paused_notification"}
      )
    end
  end

  describe "perform/1 — sustained hard-failures trigger" do
    test "deactivates integrations with 168+ consecutive hard failures even when streak is short",
         %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      # Only 3 days unhealthy — well below the 14-day calendar cutoff. The
      # hard-failure count alone should still trigger the pause.
      recent = DateTime.add(DateTime.utc_now(), -3 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :calendar, integration.id,
        became_unhealthy_at: recent,
        consecutive_hard_failures: 200
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      {:ok, paused} = CalendarIntegrationQueries.get(integration.id)
      assert paused.is_active == false

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_integration_paused_notification"}
      )
    end

    test "leaves flappy integrations alone (low consecutive hard failures, recent streak)",
         %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      recent = DateTime.add(DateTime.utc_now(), -5 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :calendar, integration.id,
        became_unhealthy_at: recent,
        consecutive_hard_failures: 10
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      {:ok, still_active} = CalendarIntegrationQueries.get(integration.id)
      assert still_active.is_active == true
    end
  end

  describe "perform/1 — common behaviour" do
    test "skips already-inactive integrations", %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: false)

      old_unhealthy = DateTime.add(DateTime.utc_now(), -15 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :calendar, integration.id,
        became_unhealthy_at: old_unhealthy,
        consecutive_hard_failures: 5
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_integration_paused_notification"}
      )
    end

    test "is_active gate prevents re-pausing on consecutive runs", %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      old_unhealthy = DateTime.add(DateTime.utc_now(), -15 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :calendar, integration.id,
        became_unhealthy_at: old_unhealthy,
        consecutive_hard_failures: 5
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})
      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      # The second run finds the integration already inactive and returns :skip
      # at the fetch_active_integration gate — it never reaches the email
      # scheduling step. Only one pause notification job must exist.
      pause_jobs =
        Enum.filter(all_enqueued(worker: EmailWorker), fn job ->
          job.args["action"] == "send_integration_paused_notification" and
            job.args["integration_id"] == integration.id
        end)

      assert length(pause_jobs) == 1
    end

    test "Oban uniqueness window prevents duplicate scheduling when integration is re-activated between runs",
         %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      old_unhealthy = DateTime.add(DateTime.utc_now(), -15 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :calendar, integration.id,
        became_unhealthy_at: old_unhealthy,
        consecutive_hard_failures: 5
      )

      # First run pauses the integration and schedules the email job.
      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      {:ok, paused} = CalendarIntegrationQueries.get(integration.id)
      assert paused.is_active == false

      # Re-activate manually so the is_active gate is no longer the guard on
      # the second run. The Oban 90-day uniqueness window is now the only
      # mechanism that must prevent a duplicate notification job.
      {:ok, reactivated} = CalendarIntegrationQueries.toggle_active(paused)
      assert reactivated.is_active == true

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      # Still exactly one pause notification job — Oban uniqueness blocked the
      # duplicate even though is_active was true at the time of the second run.
      pause_jobs =
        Enum.filter(all_enqueued(worker: EmailWorker), fn job ->
          job.args["action"] == "send_integration_paused_notification" and
            job.args["integration_id"] == integration.id
        end)

      assert length(pause_jobs) == 1
    end
  end
end
