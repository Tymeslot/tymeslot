defmodule Tymeslot.Slack.SlackQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :slack
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Slack.{SlackDeliverySchema, SlackIntegrationSchema, SlackQueries}

  describe "list_integrations/1" do
    test "returns integrations for the given user, newest first" do
      user = insert(:user)
      _other_user_integration = insert(:slack_integration)
      old = insert(:slack_integration, user: user)
      new = insert(:slack_integration, user: user)

      results = SlackQueries.list_integrations(user.id)
      assert Enum.map(results, & &1.id) == [new.id, old.id]
    end
  end

  describe "get_integration/2" do
    test "returns the integration when ID and user match" do
      integration = insert(:slack_integration)

      assert {:ok, found} = SlackQueries.get_integration(integration.id, integration.user_id)
      assert found.id == integration.id
    end

    test "returns not_found when user does not match" do
      integration = insert(:slack_integration)
      other_user = insert(:user)

      assert {:error, :not_found} = SlackQueries.get_integration(integration.id, other_user.id)
    end
  end

  describe "list_active_integrations_for_event/2" do
    test "returns only active integrations subscribed to the event" do
      user = insert(:user)

      active =
        insert(:slack_integration,
          user: user,
          events: ["meeting.created"],
          is_active: true
        )

      _inactive =
        insert(:slack_integration,
          user: user,
          events: ["meeting.created"],
          is_active: false
        )

      _wrong_event =
        insert(:slack_integration,
          user: user,
          events: ["meeting.cancelled"],
          is_active: true
        )

      _disabled =
        insert(:slack_integration,
          user: user,
          events: ["meeting.created"],
          is_active: true,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "test"
        )

      results = SlackQueries.list_active_integrations_for_event(user.id, "meeting.created")
      assert Enum.map(results, & &1.id) == [active.id]
    end

    test "excludes pending_oauth integrations (no channel_id)" do
      user = insert(:user)

      _pending =
        insert(:slack_integration,
          user: user,
          events: ["meeting.created"],
          is_active: true,
          channel_id: nil
        )

      assert [] = SlackQueries.list_active_integrations_for_event(user.id, "meeting.created")
    end
  end

  describe "create_integration/1, update_integration/2, delete_integration/1" do
    test "create_integration/1 inserts a record" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "My Workspace",
        app_mode: "oauth",
        bot_token: "xoxb-token",
        team_id: "T1",
        channel_id: "C1",
        events: ["meeting.created"]
      }

      assert {:ok, integration} = SlackQueries.create_integration(attrs)
      assert integration.name == "My Workspace"
    end

    test "update_integration/2 updates fields" do
      integration = insert(:slack_integration)
      assert {:ok, updated} = SlackQueries.update_integration(integration, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end

    test "delete_integration/1 removes the record" do
      integration = insert(:slack_integration)
      assert {:ok, _deleted} = SlackQueries.delete_integration(integration)

      assert {:error, :not_found} =
               SlackQueries.get_integration(integration.id, integration.user_id)
    end
  end

  describe "create_oauth_stub/1 and set_channel/2" do
    test "create_oauth_stub/1 persists a pending integration without channel_id" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "Acme",
        app_mode: "oauth",
        bot_token: "xoxb-stub",
        team_id: "T123",
        team_name: "Acme",
        events: ["meeting.created"]
      }

      assert {:ok, stub} = SlackQueries.create_oauth_stub(attrs)
      assert is_nil(stub.channel_id)
      assert SlackIntegrationSchema.status(stub) == :pending_oauth
    end

    test "set_channel/2 transitions a stub into an active integration" do
      user = insert(:user)

      {:ok, stub} =
        SlackQueries.create_oauth_stub(%{
          user_id: user.id,
          name: "Acme",
          app_mode: "oauth",
          bot_token: "xoxb-stub",
          team_id: "T1",
          events: ["meeting.created"]
        })

      assert {:ok, active} =
               SlackQueries.set_channel(stub, %{channel_id: "C9", channel_name: "#bookings"})

      assert active.channel_id == "C9"
      assert SlackIntegrationSchema.status(active) == :active
    end
  end

  describe "find_by_link_token/1" do
    test "returns the integration for a known token" do
      integration = insert(:slack_integration, link_token: "abc123")
      assert {:ok, found} = SlackQueries.find_by_link_token("abc123")
      assert found.id == integration.id
    end

    test "returns not_found for unknown token" do
      assert {:error, :not_found} = SlackQueries.find_by_link_token("nope")
    end
  end

  describe "toggle_integration/1 and record_success/1" do
    test "toggle_integration/1 flips is_active" do
      integration = insert(:slack_integration, is_active: true)
      assert {:ok, paused} = SlackQueries.toggle_integration(integration)
      refute paused.is_active

      assert {:ok, resumed} = SlackQueries.toggle_integration(paused)
      assert resumed.is_active
    end

    test "record_success/1 resets failure_count and bumps last_triggered_at" do
      integration = insert(:slack_integration, failure_count: 3)
      assert {:ok, updated} = SlackQueries.record_success(integration)
      assert updated.failure_count == 0
      assert updated.last_triggered_at
    end
  end

  describe "increment_failure/1" do
    test "increments failure_count and returns updated record" do
      integration = insert(:slack_integration, failure_count: 2)
      assert {:ok, updated} = SlackQueries.increment_failure(integration)
      assert updated.failure_count == 3
    end

    test "returns not_found when integration no longer exists" do
      integration = insert(:slack_integration)
      {:ok, _deleted} = SlackQueries.delete_integration(integration)
      assert {:error, :not_found} = SlackQueries.increment_failure(integration)
    end
  end

  describe "enable_integration/1" do
    test "re-enables a disabled integration and clears failure data" do
      integration =
        insert(:slack_integration,
          is_active: false,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "expired",
          failure_count: 7
        )

      assert {:ok, enabled} = SlackQueries.enable_integration(integration)
      assert enabled.is_active
      assert is_nil(enabled.disabled_at)
      assert is_nil(enabled.disabled_reason)
      assert enabled.failure_count == 0
    end
  end

  describe "delete_pending_stubs/1" do
    test "removes oauth integrations without a channel for the user" do
      user = insert(:user)

      _stub = insert(:slack_integration, user: user, app_mode: "oauth", channel_id: nil)
      kept = insert(:slack_integration, user: user)

      assert {1, _rows} = SlackQueries.delete_pending_stubs(user.id)
      assert Enum.map(SlackQueries.list_integrations(user.id), & &1.id) == [kept.id]
    end
  end

  describe "update_state/2" do
    test "disables an integration without requiring channel_id or re-encryption" do
      user = insert(:user)

      # A pending stub has no channel_id; the full changeset would reject this.
      stub =
        insert(:slack_integration,
          user: user,
          app_mode: "oauth",
          channel_id: nil
        )

      now = DateTime.utc_now()

      assert {:ok, updated} =
               SlackQueries.update_state(stub, %{
                 is_active: false,
                 disabled_at: now,
                 disabled_reason: "test auto-disable"
               })

      assert updated.is_active == false
      assert updated.disabled_reason == "test auto-disable"
    end
  end

  describe "list_deliveries/2, create_delivery/1, get_delivery_stats/2" do
    setup do
      integration = insert(:slack_integration)
      {:ok, integration: integration}
    end

    test "create_delivery/1 inserts a delivery row", %{integration: integration} do
      attrs = %{
        integration_id: integration.id,
        event_type: "meeting.created",
        response_status: 200,
        delivered_at: DateTime.utc_now(),
        attempt_count: 1
      }

      assert {:ok, %SlackDeliverySchema{}} = SlackQueries.create_delivery(attrs)
    end

    test "list_deliveries/2 returns most recent first, capped at limit", %{
      integration: integration
    } do
      for i <- 1..3 do
        {:ok, _delivery} =
          SlackQueries.create_delivery(%{
            integration_id: integration.id,
            event_type: "meeting.created",
            response_status: 200,
            attempt_count: i
          })
      end

      results = SlackQueries.list_deliveries(integration.id, limit: 2)
      assert length(results) == 2
    end

    test "get_delivery_stats/2 counts success/failure", %{integration: integration} do
      {:ok, _success} =
        SlackQueries.create_delivery(%{
          integration_id: integration.id,
          event_type: "meeting.created",
          response_status: 200,
          delivered_at: DateTime.utc_now(),
          attempt_count: 1
        })

      {:ok, _failure} =
        SlackQueries.create_delivery(%{
          integration_id: integration.id,
          event_type: "meeting.created",
          response_status: 500,
          error_message: "boom",
          attempt_count: 1
        })

      stats = SlackQueries.get_delivery_stats(integration.id)
      assert stats.total == 2
      assert stats.successful == 1
      assert stats.failed == 1
      assert stats.period_days == 7
    end
  end
end
