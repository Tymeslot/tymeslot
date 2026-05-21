defmodule TymeslotWeb.Dashboard.Automation.TelegramStateActionsTest do
  @moduledoc """
  Covers the per-card state actions — Test, Disconnect, Re-enable, Reconnect.
  The existing `TelegramEventHandlersTest` covers form lifecycle, toggle,
  delete, and shared-bot wizard entry; this suite picks up the user actions on
  already-created integrations.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :telegram
  @moduletag :live
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Telegram

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{},
      http_client_module: Tymeslot.HTTPClientMock
    )

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  defp open_telegram_tab(view) do
    view |> element("button", "Telegram") |> render_click()
    render(view)
  end

  defp own_bot_integration(user, attrs \\ %{}) do
    defaults = %{
      user: user,
      bot_mode: "own",
      bot_token_encrypted: Encryption.encrypt("1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"),
      chat_id: "123456789",
      is_active: true
    }

    insert(:telegram_integration, Map.merge(defaults, attrs))
  end

  defp shared_bot_integration(user, attrs \\ %{}) do
    defaults = %{
      user: user,
      bot_mode: "shared",
      bot_token_encrypted: nil,
      chat_id: "987654321",
      is_active: true
    }

    insert(:telegram_integration, Map.merge(defaults, attrs))
  end

  # ---------------------------------------------------------------------------
  # Test connection
  # ---------------------------------------------------------------------------

  describe "Test connection (own-bot)" do
    test "POSTs to Telegram sendMessage and shows a success flash", %{conn: conn, user: user} do
      _integration = own_bot_integration(user)

      expect(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
        assert url =~ "https://api.telegram.org/bot"
        assert url =~ "/sendMessage"
        decoded = Jason.decode!(body)
        assert decoded["chat_id"] == "123456789"
        {:ok, %{status: 200, body: Jason.encode!(%{"ok" => true, "result" => %{}})}}
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Test") |> render_click()

      assert render(view) =~ "Test message sent"
    end

    test "does not flash success when delivery fails", %{conn: conn, user: user} do
      _integration = own_bot_integration(user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: "{\"ok\":false,\"description\":\"Unauthorized\"}"}}
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Test") |> render_click()

      refute render(view) =~ "Test message sent"
    end
  end

  # ---------------------------------------------------------------------------
  # Disconnect
  # ---------------------------------------------------------------------------

  describe "Disconnect" do
    test "shared-bot integration: clears chat_id and shows a confirmation flash", %{
      conn: conn,
      user: user
    } do
      ConfigTestHelpers.setup_config(:tymeslot, telegram_shared_bot: true)

      integration = shared_bot_integration(user)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view
      |> element("button[title='Disconnect Telegram']")
      |> render_click()

      assert render(view) =~ "Telegram disconnected"

      {:ok, refreshed} = Telegram.get_integration(integration.id, user.id)
      assert refreshed.chat_id == nil
    end

    test "own-bot integrations never expose the disconnect button", %{conn: conn, user: user} do
      _integration = own_bot_integration(user)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_telegram_tab(view)

      refute html =~ "title=\"Disconnect Telegram\""
    end
  end

  # ---------------------------------------------------------------------------
  # Re-enable
  # ---------------------------------------------------------------------------

  describe "Re-enable" do
    test "transitions an auto-disabled integration back to active", %{conn: conn, user: user} do
      integration =
        own_bot_integration(user, %{
          is_active: false,
          disabled_at: DateTime.utc_now(:second),
          disabled_reason: "auth_failure"
        })

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Re-enable") |> render_click()

      assert render(view) =~ "Integration re-enabled"

      {:ok, refreshed} = Telegram.get_integration(integration.id, user.id)
      assert refreshed.is_active == true
      assert refreshed.disabled_at == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Reconnect (shared-bot)
  # ---------------------------------------------------------------------------

  describe "Reconnect (shared-bot)" do
    test "opens the wizard at step 1 with a fresh deep link", %{conn: conn, user: user} do
      ConfigTestHelpers.setup_config(:tymeslot, telegram_shared_bot: true)

      _integration =
        shared_bot_integration(user, %{
          chat_id: nil,
          link_token: "old-token-stale"
        })

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Connect") |> render_click()

      html = render(view)
      assert html =~ "Connect Telegram"
      assert html =~ "Open in Telegram"
    end
  end
end
