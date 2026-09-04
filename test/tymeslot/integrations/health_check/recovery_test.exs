defmodule Tymeslot.Integrations.HealthCheck.RecoveryTest do
  @moduledoc """
  Covers the two success signals that reach the health row outside the
  scheduled probe.

  `HealthCheck.mark_user_recovered/2` is a deliberate act by the owner — new
  credentials, a reactivation — and resets the row to a healthy baseline.
  `mark_synced_successfully/2` is the integration's own periodic work
  completing, and clears the failed-sync streak *only*: ending the unhealthy
  episode stays with the probe's flap-protected recovery, so that a server
  answering roughly one sync a day cannot restart the 48-hour notification
  clock every day.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Tymeslot.Factory
  import Tymeslot.TestFixtures

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.HealthCheck.ResponseHandler
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup do
    user = create_user_fixture()
    %{user: user}
  end

  defp insert_unhealthy_row(user, type, integration_id) do
    {:ok, row} =
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: type,
        integration_id: integration_id,
        user_id: user.id,
        status: "unhealthy",
        failures: 5,
        consecutive_hard_failures: 5,
        successes: 0,
        backoff_ms: :timer.hours(1),
        last_check_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        last_error_class: "hard",
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -3 * 24 * 3600, :second),
        notification_sent_at: DateTime.add(DateTime.utc_now(), -2 * 24 * 3600, :second)
      })
      |> Repo.insert()

    row
  end

  describe "mark_user_recovered/2" do
    test "resets the health row to a healthy baseline", %{user: user} do
      insert_unhealthy_row(user, "calendar", 200)

      :ok = HealthCheck.mark_user_recovered(:calendar, 200)

      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, 200)
      assert row.status == "healthy"
      assert row.failures == 0
      assert row.consecutive_hard_failures == 0
      assert row.became_unhealthy_at == nil
      assert row.notification_sent_at == nil
    end

    test "enqueues an immediate verification probe", %{user: user} do
      insert_unhealthy_row(user, "calendar", 201)

      :ok = HealthCheck.mark_user_recovered(:calendar, 201)

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => 201}
      )
    end

    test "leaves a row the very next successful probe keeps healthy", %{user: user} do
      insert_unhealthy_row(user, "calendar", 202)

      :ok = HealthCheck.mark_user_recovered(:calendar, 202)

      # The three steps HealthCheck runs around a probe: read the state, fold
      # the result in, persist. A reset row starts at zero successes, below the
      # recovery threshold, so it is the row's healthy status that keeps the
      # verification probe just enqueued from knocking the badge back to
      # :degraded.
      :calendar
      |> Monitor.get_state(202, user.id)
      |> then(&Monitor.update_health(&1, {:ok, :probe_succeeded}))
      |> then(&Monitor.put_state(:calendar, 202, &1))

      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, 202)
      assert row.status == "healthy"
      assert row.successes == 1
    end

    test "is safe to call when no row exists" do
      assert :ok = HealthCheck.mark_user_recovered(:calendar, 9_999_999)

      # Probe is still enqueued — orchestration handles missing integrations
      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => 9_999_999}
      )
    end
  end

  describe "mark_synced_successfully/2" do
    test "clears the failed-sync streak that raised the badge", %{user: user} do
      insert_unhealthy_row(user, "calendar", 301)

      IntegrationHealthStateQueries.update_fields(:calendar, 301, consecutive_sync_failures: 7)

      :ok = HealthCheck.mark_synced_successfully(:calendar, 301)

      # This is the streak's only reset path: nothing else zeroes it, so a
      # successful sync that left it standing would keep the integration
      # permanently unhealthy.
      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, 301)
      assert row.consecutive_sync_failures == 0
    end

    test "leaves the unhealthy episode and its 48-hour clock standing", %{user: user} do
      inserted = insert_unhealthy_row(user, "calendar", 300)

      IntegrationHealthStateQueries.update_fields(:calendar, 300, consecutive_sync_failures: 7)

      :ok = HealthCheck.mark_synced_successfully(:calendar, 300)

      # One completed cycle says the streak has ended, not that the outage
      # has. A server answering roughly one sync a day would otherwise reset
      # `became_unhealthy_at` daily and never reach the 48-hour notification.
      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, 300)
      assert row.status == "unhealthy"
      assert row.became_unhealthy_at == inserted.became_unhealthy_at
      assert row.notification_sent_at == inserted.notification_sent_at
      assert row.failures == inserted.failures
      assert row.consecutive_hard_failures == inserted.consecutive_hard_failures
    end

    test "does not enqueue a probe", %{user: user} do
      insert_unhealthy_row(user, "calendar", 302)

      :ok = HealthCheck.mark_synced_successfully(:calendar, 302)

      refute_enqueued(worker: IntegrationHealthWorker)
    end

    test "is safe to call when no row exists" do
      assert :ok = HealthCheck.mark_synced_successfully(:calendar, 9_999_998)
      assert IntegrationHealthStateQueries.get(:calendar, 9_999_998) == {:error, :not_found}
    end
  end

  describe "a server that fails most syncs but answers one a day" do
    setup %{user: user} do
      %{integration: insert(:calendar_integration, user: user, is_active: true)}
    end

    defp fail_whole_streak(integration) do
      for _cycle <- 1..Monitor.sync_failure_threshold() do
        :ok = HealthCheck.record_sync_failure(:calendar, integration)
      end
    end

    defp backdate_unhealthy_since(integration, hours) do
      IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
      )
    end

    test "reaches the badge, and the daily success does not lower it", %{
      integration: integration
    } do
      fail_whole_streak(integration)

      {:ok, raised} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert raised.status == "unhealthy"
      assert %DateTime{} = raised.became_unhealthy_at

      :ok = HealthCheck.mark_synced_successfully(:calendar, integration.id)

      {:ok, after_success} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert after_success.consecutive_sync_failures == 0
      assert after_success.status == "unhealthy"
      assert after_success.became_unhealthy_at == raised.became_unhealthy_at
    end

    test "notifies the owner once after 48 hours of the pattern", %{integration: integration} do
      fail_whole_streak(integration)

      # Nothing yet: the episode is minutes old, not two days.
      refute_enqueued(worker: EmailWorker)

      # Two days of the same shape — a run of failures, one success a day —
      # with the episode aged to just past the 48-hour threshold. If the
      # success reset the episode, every one of these cycles would stamp a
      # fresh `became_unhealthy_at` and the email below would never be due.
      backdate_unhealthy_since(integration, 49)

      for _day <- 1..2 do
        :ok = HealthCheck.mark_synced_successfully(:calendar, integration.id)
        fail_whole_streak(integration)
      end

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "user_id" => integration.user_id,
          "integration_id" => integration.id,
          "integration_type" => "calendar"
        }
      )

      # Once, not once per failing cycle: the 30-day uniqueness window on the
      # job is what holds while `notification_sent_at` is still unstamped.
      assert length(all_enqueued(worker: EmailWorker)) == 1
    end

    test "the probe's recovery path is what finally clears the episode", %{
      integration: integration,
      user: user
    } do
      fail_whole_streak(integration)
      backdate_unhealthy_since(integration, 49)
      :ok = HealthCheck.mark_synced_successfully(:calendar, integration.id)

      {:ok, episode} = IntegrationHealthStateQueries.get(:calendar, integration.id)

      # Two consecutive successful probes: the recovery threshold. The first
      # is not enough to call the integration healthy — that is the flap
      # protection — and the second takes it there and clears the episode.
      assert probe_success(integration, user).status == :degraded

      {:ok, midway} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert midway.became_unhealthy_at == episode.became_unhealthy_at

      assert probe_success(integration, user).status == :healthy

      {:ok, row} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert row.status == "healthy"
      assert row.became_unhealthy_at == nil
      assert row.notification_sent_at == nil
    end

    # The steps `HealthCheck` runs around one successful probe: read the state,
    # fold the result in, detect the transition, persist, respond.
    defp probe_success(integration, user) do
      old_state = Monitor.get_state(:calendar, integration.id, user.id)
      new_state = Monitor.update_health(old_state, {:ok, :probe_succeeded})
      transition = Monitor.detect_transition(old_state, new_state)

      Monitor.put_state(:calendar, integration.id, new_state)
      ResponseHandler.handle_transition(:calendar, integration, transition, new_state)

      new_state
    end
  end
end
