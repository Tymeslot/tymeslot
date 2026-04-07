defmodule Tymeslot.TelegramTest do
  use Tymeslot.DataCase, async: false

  @moduletag :telegram
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.TelegramIntegrationSchema

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      environment: :test
    )

    :ok
  end

  describe "CRUD" do
    test "create_integration/2 creates an integration" do
      user = insert(:user)

      assert {:ok, integration} =
               Telegram.create_integration(user.id, %{
                 name: "Test Bot",
                 bot_token: "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789",
                 chat_id: "123456789",
                 events: ["meeting.created"]
               })

      assert integration.name == "Test Bot"
      assert integration.chat_id == "123456789"
      assert integration.bot_mode == "own"
      assert integration.events == ["meeting.created"]
    end

    test "list_integrations/1 returns user's integrations with status" do
      user = insert(:user)
      insert(:telegram_integration, user: user)

      integrations = Telegram.list_integrations(user.id)
      assert length(integrations) == 1
      assert hd(integrations).status != nil
    end

    test "get_integration/2 returns integration with status" do
      integration = insert(:telegram_integration)

      assert {:ok, found} = Telegram.get_integration(integration.id, integration.user_id)
      assert found.id == integration.id
      assert found.status == :active
    end

    test "update_integration/2 updates the integration" do
      integration = insert(:telegram_integration)

      assert {:ok, updated} =
               Telegram.update_integration(integration, %{name: "Updated Name"})

      assert updated.name == "Updated Name"
    end

    test "delete_integration/1 removes the integration" do
      integration = insert(:telegram_integration)
      assert {:ok, _deleted} = Telegram.delete_integration(integration)
      assert {:error, :not_found} = Telegram.get_integration(integration.id, integration.user_id)
    end
  end

  describe "status derivation" do
    test "active when is_active=true and chat_id set" do
      integration = insert(:telegram_integration, is_active: true)
      assert {:ok, found} = Telegram.get_integration(integration.id, integration.user_id)
      assert found.status == :active
    end

    test "paused when is_active=false and no disabled_at" do
      integration = insert(:telegram_integration, is_active: false)
      assert {:ok, found} = Telegram.get_integration(integration.id, integration.user_id)
      assert found.status == :paused
    end

    test "auto_disabled when is_active=false and disabled_at set" do
      integration =
        insert(:telegram_integration,
          is_active: false,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Too many failures"
        )

      assert {:ok, found} = Telegram.get_integration(integration.id, integration.user_id)
      assert found.status == :auto_disabled
    end

    test "pending_link when chat_id is nil" do
      integration = insert(:telegram_integration, chat_id: nil)
      assert {:ok, found} = Telegram.get_integration(integration.id, integration.user_id)
      assert found.status == :pending_link
    end
  end

  describe "toggle_integration/1" do
    test "toggles active to paused" do
      integration = insert(:telegram_integration, is_active: true)
      assert {:ok, toggled} = Telegram.toggle_integration(integration)
      assert toggled.is_active == false
    end

    test "toggles paused to active" do
      integration = insert(:telegram_integration, is_active: false)
      assert {:ok, toggled} = Telegram.toggle_integration(integration)
      assert toggled.is_active == true
    end

    test "returns error for pending_link state" do
      integration = insert(:telegram_integration, chat_id: nil)
      assert {:error, :invalid_state} = Telegram.toggle_integration(integration)
    end
  end

  describe "reenable_integration/1" do
    test "re-enables auto_disabled integration" do
      integration =
        insert(:telegram_integration,
          is_active: false,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "failures",
          failure_count: 10
        )

      assert {:ok, reenabled} = Telegram.reenable_integration(integration)
      assert reenabled.is_active == true
      assert is_nil(reenabled.disabled_at)
      assert is_nil(reenabled.disabled_reason)
      assert reenabled.failure_count == 0
    end
  end

  describe "resolve_bot_token/1" do
    test "resolves token for own-bot mode" do
      integration = insert(:telegram_integration)
      assert {:ok, token} = Telegram.resolve_bot_token(integration)
      assert is_binary(token)
    end

    test "resolves token for shared-bot mode from app config" do
      setup_config(:tymeslot, telegram_bot_token: "shared_token_123")

      integration = %TelegramIntegrationSchema{bot_mode: "shared"}
      assert {:ok, "shared_token_123"} = Telegram.resolve_bot_token(integration)
    end

    test "returns error when shared token not configured" do
      setup_config(:tymeslot, telegram_bot_token: nil)

      integration = %TelegramIntegrationSchema{bot_mode: "shared"}
      assert {:error, :no_shared_token} = Telegram.resolve_bot_token(integration)
    end
  end

  describe "account linking" do
    test "generate_link_token/0 and handle_start_payload/2 link account" do
      token = Telegram.generate_link_token()

      integration =
        insert(:telegram_integration, chat_id: nil, bot_mode: "shared", link_token: token)

      # Subscribe to PubSub for link notification
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "telegram_link:#{integration.user_id}")

      assert {:ok, updated} = Telegram.handle_start_payload(token, "999888777")
      assert updated.chat_id == "999888777"

      # Verify PubSub broadcast
      expected_id = integration.id
      assert_receive {:telegram_linked, ^expected_id, "999888777"}
    end

    test "handle_start_payload/2 rejects own-bot integrations" do
      token = Telegram.generate_link_token()

      integration =
        insert(:telegram_integration, chat_id: nil, bot_mode: "own", link_token: token)

      assert {:error, :wrong_bot_mode} = Telegram.handle_start_payload(token, "999888777")

      # chat_id must remain nil — no update occurred
      reloaded = Repo.get(TelegramIntegrationSchema, integration.id)
      assert is_nil(reloaded.chat_id)
    end

    test "handle_start_payload/2 rejects unknown tokens" do
      _integration = insert(:telegram_integration, chat_id: nil, bot_mode: "shared")

      assert {:error, :not_found} =
               Telegram.handle_start_payload("nonexistent_token", "999888777")
    end

    test "build_deep_link/1 returns Telegram URL" do
      url = Telegram.build_deep_link("test_token")
      assert url =~ "https://t.me/"
      assert url =~ "test_token"
    end
  end

  describe "disconnect_integration/1 and reconnect_integration/1" do
    test "disconnect_integration/1 clears chat_id on shared-bot integrations" do
      integration = insert(:telegram_integration, bot_mode: "shared", chat_id: "123456")

      assert {:ok, updated} = Telegram.disconnect_integration(integration)
      assert is_nil(updated.chat_id)
    end

    test "disconnect_integration/1 returns error for own-bot integrations" do
      integration = insert(:telegram_integration, bot_mode: "own")
      assert {:error, :own_bot_mode} = Telegram.disconnect_integration(integration)
    end

    test "reconnect_integration/1 clears chat_id and returns deep link for shared-bot" do
      setup_config(:tymeslot,
        telegram_bot_token: "shared_token",
        telegram_bot_username: "TestBot"
      )

      integration = insert(:telegram_integration, bot_mode: "shared", chat_id: "123456")

      assert {:ok, updated, deep_link} = Telegram.reconnect_integration(integration)
      assert is_nil(updated.chat_id)
      assert deep_link =~ "https://t.me/TestBot"
    end

    test "reconnect_integration/1 returns error for own-bot integrations" do
      integration = insert(:telegram_integration, bot_mode: "own")
      assert {:error, :own_bot_mode} = Telegram.reconnect_integration(integration)
    end
  end

  describe "create_integration/2 - feature flag enforcement" do
    test "returns error when telegram feature is disabled" do
      setup_config(:tymeslot, telegram_notifications_allowed: false)
      user = insert(:user)

      assert {:error, :feature_disabled} =
               Telegram.create_integration(user.id, %{
                 name: "Test Bot",
                 bot_token: "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789",
                 chat_id: "123456789",
                 events: ["meeting.created"]
               })
    end
  end

  describe "available_events/0" do
    test "returns event definitions" do
      events = Telegram.available_events()
      assert length(events) == 3
      assert Enum.all?(events, &Map.has_key?(&1, :value))
    end
  end
end
