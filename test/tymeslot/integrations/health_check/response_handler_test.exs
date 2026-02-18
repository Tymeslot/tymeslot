defmodule Tymeslot.Integrations.HealthCheck.ResponseHandlerTest do
  @moduletag :integrations
  use Tymeslot.DataCase, async: false

  alias Tymeslot.DatabaseQueries.{CalendarIntegrationQueries, VideoIntegrationQueries}
  alias Tymeslot.Integrations.HealthCheck.ResponseHandler

  describe "handle_transition/3 with no change" do
  @moduletag :integrations
    test "does nothing for no_change transitions" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:no_change, :healthy, :healthy}
             ) == :ok

      # Verify integration is still active
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end
  end

  describe "handle_transition/3 with initial failure" do
    test "deactivates calendar integration on initial failure" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:initial_failure, nil, :unhealthy}
             ) == :ok

      # Verify integration was deactivated
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      refute updated.is_active
    end

    test "deactivates video integration on initial failure" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:initial_failure, nil, :unhealthy}
             ) == :ok

      # Verify integration was deactivated
      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      refute updated.is_active
    end
  end

  describe "handle_transition/3 with became unhealthy" do
    test "deactivates calendar integration when becoming unhealthy" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_unhealthy, :degraded, :unhealthy}
             ) == :ok

      # Verify integration was deactivated
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      refute updated.is_active
    end

    test "deactivates video integration when becoming unhealthy" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:became_unhealthy, :healthy, :unhealthy}
             ) == :ok

      # Verify integration was deactivated
      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      refute updated.is_active
    end
  end

  describe "handle_transition/3 with became healthy" do
    test "logs recovery from unhealthy to healthy" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: false)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_healthy, :unhealthy, :healthy}
             ) == :ok

      # Note: Recovery doesn't automatically re-activate integrations
      # User must manually re-enable them
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      refute updated.is_active
    end

    test "handles recovery for video integrations" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: false)

      assert ResponseHandler.handle_transition(
               :video,
               integration,
               {:became_healthy, :unhealthy, :healthy}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      refute updated.is_active
    end
  end

  describe "handle_transition/3 with became degraded" do
    test "logs warning but does not deactivate" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_degraded, :healthy, :degraded}
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
               {:became_degraded, :healthy, :degraded}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end
  end

  describe "deactivation with already inactive integration" do
    test "handles already inactive calendar integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: false)

      # Should succeed even though integration is already inactive
      assert ResponseHandler.handle_transition(
               :calendar,
               integration,
               {:became_unhealthy, :healthy, :unhealthy}
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
               {:became_unhealthy, :healthy, :unhealthy}
             ) == :ok

      {:ok, updated} = VideoIntegrationQueries.get(integration.id)
      refute updated.is_active
    end
  end
end
