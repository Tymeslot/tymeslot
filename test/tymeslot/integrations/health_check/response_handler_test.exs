defmodule Tymeslot.Integrations.HealthCheck.ResponseHandlerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  alias Tymeslot.Integrations.HealthCheck.ResponseHandler
  alias Tymeslot.Workers.EmailWorker

  # Minimal health state that does not trigger notifications
  # (became_unhealthy_at is nil, so maybe_notify_user short-circuits)
  defp healthy_health_state do
    %{
      became_unhealthy_at: nil,
      notification_sent_at: nil,
      status: :healthy,
      failures: 0,
      successes: 0
    }
  end

  defp unhealthy_health_state do
    %{
      became_unhealthy_at: nil,
      notification_sent_at: nil,
      status: :unhealthy,
      failures: 3,
      successes: 0
    }
  end

  describe "handle_transition/4 with no change" do
    test "does nothing for no_change transitions" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:no_change, :healthy, :healthy},
               healthy_health_state()
             ) == :ok

      # Verify integration is still active
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end
  end

  describe "handle_transition/4 with initial failure" do
    test "does not deactivate calendar integration on initial failure" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:initial_failure, nil, :unhealthy},
               unhealthy_health_state()
             ) == :ok

      # Verify integration remains active
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end

    test "does not deactivate video integration on initial failure" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:initial_failure, nil, :unhealthy},
               unhealthy_health_state()
             ) == :ok

      # Verify integration remains active
      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end
  end

  describe "handle_transition/4 with became unhealthy" do
    test "does not deactivate calendar integration when becoming unhealthy" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_unhealthy, :degraded, :unhealthy},
               unhealthy_health_state()
             ) == :ok

      # Verify integration remains active
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end

    test "does not deactivate video integration when becoming unhealthy" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:became_unhealthy, :healthy, :unhealthy},
               unhealthy_health_state()
             ) == :ok

      # Verify integration remains active
      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end
  end

  describe "handle_transition/4 with became healthy" do
    test "sends recovery alert but keeps integration active" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_healthy, :unhealthy, :healthy},
               healthy_health_state()
             ) == :ok

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end

    test "sends recovery alert for video integrations and keeps integration active" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:became_healthy, :unhealthy, :healthy},
               healthy_health_state()
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end
  end

  describe "handle_transition/4 with became degraded" do
    test "logs warning but does not deactivate" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_degraded, :healthy, :degraded},
               healthy_health_state()
             ) == :ok

      # Verify integration remains active
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end

    test "handles degraded state for video integrations" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:became_degraded, :healthy, :degraded},
               healthy_health_state()
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end
  end

  describe "deactivation with already inactive integration" do
    test "handles already inactive calendar integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: false)

      # Should succeed and leave the integration inactive (as it was manually deactivated)
      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_unhealthy, :healthy, :unhealthy},
               unhealthy_health_state()
             ) == :ok

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      refute updated.is_active
    end

    test "handles already inactive video integration" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: false)

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:became_unhealthy, :healthy, :unhealthy},
               unhealthy_health_state()
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      refute updated.is_active
    end
  end

  describe "48-hour notification" do
    test "schedules email when unhealthy for over 48 hours" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      health_state = %{
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -49, :hour),
        notification_sent_at: nil,
        status: :unhealthy,
        failures: 3,
        successes: 0
      }

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:no_change, :unhealthy, :unhealthy},
               health_state
             ) == :ok

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "calendar"
        }
      )
    end

    test "does not schedule email before 48 hours" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      health_state = %{
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -47, :hour),
        notification_sent_at: nil,
        status: :unhealthy,
        failures: 3,
        successes: 0
      }

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:no_change, :unhealthy, :unhealthy},
               health_state
             ) == :ok

      refute_enqueued(worker: EmailWorker)
    end

    test "does not schedule email when became_unhealthy_at is nil" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:no_change, :unhealthy, :unhealthy},
               unhealthy_health_state()
             ) == :ok

      refute_enqueued(worker: EmailWorker)
    end

    test "respects 30-day cooldown after previous notification" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      health_state = %{
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -49, :hour),
        notification_sent_at: DateTime.add(DateTime.utc_now(), -15, :day),
        status: :unhealthy,
        failures: 3,
        successes: 0
      }

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:no_change, :unhealthy, :unhealthy},
               health_state
             ) == :ok

      refute_enqueued(worker: EmailWorker)
    end

    test "sends again after 30-day cooldown expires" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      health_state = %{
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -49, :hour),
        notification_sent_at: DateTime.add(DateTime.utc_now(), -31, :day),
        status: :unhealthy,
        failures: 3,
        successes: 0
      }

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:no_change, :unhealthy, :unhealthy},
               health_state
             ) == :ok

      assert_enqueued(worker: EmailWorker)
    end

    test "schedules email on initial_failure when already unhealthy for 48+ hours" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      health_state = %{
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -50, :hour),
        notification_sent_at: nil,
        status: :unhealthy,
        failures: 3,
        successes: 0
      }

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:initial_failure, nil, :unhealthy},
               health_state
             ) == :ok

      assert_enqueued(worker: EmailWorker)
    end

    test "schedules email on became_unhealthy when already past 48 hours" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      health_state = %{
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -50, :hour),
        notification_sent_at: nil,
        status: :unhealthy,
        failures: 3,
        successes: 0
      }

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:became_unhealthy, :degraded, :unhealthy},
               health_state
             ) == :ok

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "integration_type" => "video"
        }
      )
    end
  end

  describe "handle_transition/5 with explicit now" do
    test "schedules notification when unhealthy for 48+ hours" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      health_state = %{
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -49, :hour),
        notification_sent_at: nil,
        status: :unhealthy,
        failures: 5,
        successes: 0
      }

      now = DateTime.utc_now()

      ResponseHandler.handle_transition(
        :calendar,
        integration,
        {:no_change, :unhealthy, :unhealthy},
        health_state,
        now
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "user_id" => user.id
        }
      )
    end

    test "does not schedule notification when unhealthy for less than 48 hours" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      health_state = %{
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -24, :hour),
        notification_sent_at: nil,
        status: :unhealthy,
        failures: 5,
        successes: 0
      }

      now = DateTime.utc_now()

      ResponseHandler.handle_transition(
        :calendar,
        integration,
        {:no_change, :unhealthy, :unhealthy},
        health_state,
        now
      )

      refute_enqueued(worker: EmailWorker)
    end
  end

  describe "recovery clears notification state" do
    test "clears became_unhealthy_at and notification_sent_at on recovery" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      # Seed health state record with unhealthy timestamps
      IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
        status: "unhealthy",
        failures: 3,
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -50, :hour),
        notification_sent_at: DateTime.add(DateTime.utc_now(), -2, :day)
      )

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_healthy, :unhealthy, :healthy},
               healthy_health_state()
             ) == :ok

      {:ok, record} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert is_nil(record.became_unhealthy_at)
      assert is_nil(record.notification_sent_at)
    end
  end
end
