defmodule Tymeslot.TelegramTest do
  use Tymeslot.DataCase, async: false

  @moduletag :telegram
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Telegram.TelegramQueries

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
      assert hd(integrations).status == :active
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
      # The factory stores this token encrypted; resolving must decrypt it back.
      assert {:ok, "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"} =
               Telegram.resolve_bot_token(integration)
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
        insert(:telegram_integration,
          chat_id: nil,
          bot_mode: "shared",
          link_token: token,
          link_token_issued_at: DateTime.utc_now(:second)
        )

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
        insert(:telegram_integration,
          chat_id: nil,
          bot_mode: "own",
          link_token: token,
          link_token_issued_at: DateTime.utc_now(:second)
        )

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

    test "handle_start_payload/2 records when the integration was first linked" do
      token = Telegram.generate_link_token()

      insert(:telegram_integration,
        chat_id: nil,
        bot_mode: "shared",
        link_token: token,
        link_token_issued_at: DateTime.utc_now(:second)
      )

      assert {:ok, updated} = Telegram.handle_start_payload(token, "999888777")
      assert %DateTime{} = updated.linked_at
      assert is_nil(updated.link_token)
      assert is_nil(updated.link_token_issued_at)
    end

    test "handle_start_payload/2 refuses a token older than the link TTL" do
      token = Telegram.generate_link_token()

      issued_at =
        DateTime.add(
          DateTime.utc_now(:second),
          -Telegram.link_token_ttl_ms() - 1_000,
          :millisecond
        )

      integration =
        insert(:telegram_integration,
          chat_id: nil,
          bot_mode: "shared",
          link_token: token,
          link_token_issued_at: issued_at
        )

      assert {:error, :not_found} = Telegram.handle_start_payload(token, "999888777")
      assert is_nil(Repo.get(TelegramIntegrationSchema, integration.id).chat_id)
    end

    test "handle_start_payload/2 refuses a token with no recorded issue time" do
      token = Telegram.generate_link_token()
      insert(:telegram_integration, chat_id: nil, bot_mode: "shared", link_token: token)

      assert {:error, :not_found} = Telegram.handle_start_payload(token, "999888777")
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

    test "disconnect_integration/1 keeps the record that the integration was linked" do
      linked_at = DateTime.add(DateTime.utc_now(:second), -86_400, :second)

      integration =
        insert(:telegram_integration, bot_mode: "shared", chat_id: "123456", linked_at: linked_at)

      assert {:ok, updated} = Telegram.disconnect_integration(integration)
      assert updated.linked_at == linked_at
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

    test "reconnect_integration/1 issues a token the bot accepts" do
      integration = insert(:telegram_integration, bot_mode: "shared", chat_id: "123456")

      assert {:ok, updated, _deep_link} = Telegram.reconnect_integration(integration)
      assert {:ok, linked} = Telegram.handle_start_payload(updated.link_token, "654321")
      assert linked.id == integration.id
    end

    test "reconnect_integration/1 returns not_found when the integration is gone" do
      integration = insert(:telegram_integration, bot_mode: "shared", chat_id: "123456")
      Repo.delete!(integration)

      assert {:error, :not_found} = Telegram.reconnect_integration(integration)
    end

    test "reconnect_integration/1 returns error for own-bot integrations" do
      integration = insert(:telegram_integration, bot_mode: "own")
      assert {:error, :own_bot_mode} = Telegram.reconnect_integration(integration)
    end
  end

  describe "start_link_flow/1" do
    setup do
      setup_config(:tymeslot, telegram_shared_bot: true, telegram_bot_username: "TestBot")
      {:ok, user: insert(:user)}
    end

    test "creates one unlinked stub and a deep link carrying its token", %{user: user} do
      assert {:ok, stub, deep_link} = Telegram.start_link_flow(user.id)

      assert deep_link == "https://t.me/TestBot?start=#{stub.link_token}"
      assert stub.link_token =~ ~r/\A[A-Za-z0-9_-]{32}\z/
      assert %DateTime{} = stub.link_token_issued_at
      assert %{bot_mode: "shared", chat_id: nil, linked_at: nil} = stub
      assert stub.events == ["meeting.created"]
      assert [%{id: id}] = Telegram.list_integrations(user.id)
      assert id == stub.id
    end

    test "names the stub in the caller's locale", %{user: user} do
      {:ok, stub, _deep_link} =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn -> Telegram.start_link_flow(user.id) end)

      assert stub.name == "Mein Telegram"
    end

    test "replaces an older never-linked stub", %{user: user} do
      old_stub = pending_stub(user)

      assert {:ok, stub, _deep_link} = Telegram.start_link_flow(user.id)

      refute Repo.get(TelegramIntegrationSchema, old_stub.id)
      assert [%{id: id}] = Telegram.list_integrations(user.id)
      assert id == stub.id
    end

    test "keeps an integration that was linked and then disconnected", %{user: user} do
      disconnected = disconnected_integration(user)

      assert {:ok, _stub, _deep_link} = Telegram.start_link_flow(user.id)

      assert Repo.get(TelegramIntegrationSchema, disconnected.id)
    end

    test "deletes nothing when the plan does not allow automations", %{user: user} do
      setup_config(:tymeslot, feature_access_checker: __MODULE__.InsufficientPlanChecker)
      stub = pending_stub(user)

      assert {:error, :insufficient_plan} = Telegram.start_link_flow(user.id)
      assert [%{id: id}] = Repo.all(TelegramIntegrationSchema)
      assert id == stub.id
    end

    test "deletes nothing when Telegram is disabled", %{user: user} do
      setup_config(:tymeslot, telegram_notifications_allowed: false)
      stub = pending_stub(user)

      assert {:error, :feature_disabled} = Telegram.start_link_flow(user.id)
      assert [%{id: id}] = Repo.all(TelegramIntegrationSchema)
      assert id == stub.id
    end

    test "refuses to start in own-bot mode and deletes nothing", %{user: user} do
      setup_config(:tymeslot, telegram_shared_bot: false)
      stub = pending_stub(user)

      assert {:error, :own_bot_mode} = Telegram.start_link_flow(user.id)
      assert [%{id: id}] = Repo.all(TelegramIntegrationSchema)
      assert id == stub.id
    end
  end

  describe "discard_pending/1" do
    test "deletes a never-linked stub" do
      stub = pending_stub(insert(:user))

      assert :ok = Telegram.discard_pending(stub)
      refute Repo.get(TelegramIntegrationSchema, stub.id)
    end

    test "keeps a stub the bot linked after it was loaded" do
      stub = pending_stub(insert(:user))
      {:ok, _linked} = TelegramQueries.update_integration(stub, %{chat_id: "777"})

      assert :ok = Telegram.discard_pending(stub)
      assert %{chat_id: "777"} = Repo.get(TelegramIntegrationSchema, stub.id)
    end

    test "keeps a disconnected integration" do
      disconnected = disconnected_integration(insert(:user))

      assert :ok = Telegram.discard_pending(disconnected)
      assert Repo.get(TelegramIntegrationSchema, disconnected.id)
    end
  end

  describe "refresh_link_token/1" do
    test "returns not_found when the stub was deleted elsewhere" do
      stub = pending_stub(insert(:user))
      Repo.delete!(stub)

      assert {:error, :not_found} = Telegram.refresh_link_token(stub)
    end
  end

  describe "list_integrations/1 stub visibility" do
    test "keeps a disconnected integration older than the stub TTL" do
      user = insert(:user)
      disconnected = disconnected_integration(user)

      assert [%{id: id}] = Telegram.list_integrations(user.id)
      assert id == disconnected.id
    end

    test "hides a never-linked stub older than the stub TTL without deleting it" do
      user = insert(:user)
      stub = pending_stub(user, inserted_at: an_hour_ago())

      assert Telegram.list_integrations(user.id) == []
      assert Repo.get(TelegramIntegrationSchema, stub.id)
    end

    test "shows a never-linked stub created within the stub TTL" do
      user = insert(:user)
      stub = pending_stub(user)

      assert [%{id: id, status: :pending_link}] = Telegram.list_integrations(user.id)
      assert id == stub.id
    end

    test "keeps an old stub whose link token was issued within the TTL" do
      user = insert(:user)

      stub =
        pending_stub(user,
          inserted_at: an_hour_ago(),
          link_token_issued_at: DateTime.utc_now(:second)
        )

      assert [%{id: id}] = Telegram.list_integrations(user.id)
      assert id == stub.id
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

  describe "TelegramQueries.list_active_integrations_for_event/2 — chat_id exclusion" do
    test "excludes integrations with chat_id nil even when otherwise active" do
      user = insert(:user)

      # Integration with chat_id: nil — pending_link status; must not appear
      insert(:telegram_integration,
        user: user,
        chat_id: nil,
        is_active: true,
        events: ["meeting.created"]
      )

      # Integration with a real chat_id — must appear in results
      linked =
        insert(:telegram_integration,
          user: user,
          chat_id: "999888777",
          is_active: true,
          events: ["meeting.created"]
        )

      results = TelegramQueries.list_active_integrations_for_event(user.id, "meeting.created")

      assert length(results) == 1
      assert hd(results).id == linked.id
    end
  end

  defp pending_stub(user, attrs \\ []) do
    defaults = [
      user: user,
      bot_mode: "shared",
      chat_id: nil,
      link_token: Telegram.generate_link_token()
    ]

    insert(:telegram_integration, Keyword.merge(defaults, attrs))
  end

  defp disconnected_integration(user) do
    insert(:telegram_integration,
      user: user,
      bot_mode: "shared",
      chat_id: nil,
      linked_at: an_hour_ago(),
      inserted_at: an_hour_ago()
    )
  end

  defp an_hour_ago, do: DateTime.add(DateTime.utc_now(:second), -3600, :second)
end

defmodule Tymeslot.TelegramTest.InsufficientPlanChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: :ok | {:error, :insufficient_plan}
  def check_access(_user_id, :automations_allowed), do: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: :ok
end
