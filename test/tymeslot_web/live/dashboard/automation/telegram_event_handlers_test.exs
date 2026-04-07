defmodule TymeslotWeb.Dashboard.Automation.TelegramEventHandlersTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :telegram
  @moduletag :live
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Telegram

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  # Navigates to /dashboard/automation and switches to the Telegram tab.
  defp open_telegram_tab(view) do
    view |> element("button", "Telegram") |> render_click()
    render(view)
  end

  # ---------------------------------------------------------------------------
  # Empty state
  # ---------------------------------------------------------------------------

  describe "empty state" do
    test "shows empty state with add button when no integrations exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_telegram_tab(view)

      assert html =~ "No Telegram Integrations"
      assert html =~ "Add Telegram Account"
    end
  end

  # ---------------------------------------------------------------------------
  # Create form — own-bot mode
  # ---------------------------------------------------------------------------

  describe "create form (own-bot mode)" do
    test "opens the form with bot token and chat ID fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()
      html = render(view)

      assert html =~ "Integration Details"
      assert html =~ "Bot Token"
      assert html =~ "Chat ID"
    end

    test "keeps the form open when required fields are absent on submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)
      view |> element("button", "Add Telegram Account") |> render_click()

      # Submit with only a name — bot_token, chat_id, and events all absent.
      # Validation must reject this without making any HTTP call to Telegram.
      view
      |> form("#telegram-form", %{"telegram" => %{"name" => "Test Bot"}})
      |> render_submit()

      assert render(view) =~ "Integration Details"
    end

    test "closes form and returns to list on cancel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()
      assert render(view) =~ "Integration Details"

      view |> element("button", "Close") |> render_click()
      assert render(view) =~ "No Telegram Integrations"
    end
  end

  # ---------------------------------------------------------------------------
  # Edit integration
  # ---------------------------------------------------------------------------

  describe "edit integration" do
    setup %{user: user} do
      {:ok, integration: insert(:telegram_integration, user: user)}
    end

    test "opens edit form pre-filled with existing values", %{
      conn: conn,
      integration: integration
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button[title='Edit']") |> render_click()
      html = render(view)

      assert html =~ integration.name
      assert html =~ "Integration Details"
    end

    test "updates name and shows success flash", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button[title='Edit']") |> render_click()

      view
      |> form("#telegram-form", %{"telegram" => %{"name" => "Renamed Integration"}})
      |> render_submit()

      assert render(view) =~ "Integration updated successfully"
      assert render(view) =~ "Renamed Integration"

      {:ok, refreshed} = Telegram.get_integration(integration.id, user.id)
      assert refreshed.name == "Renamed Integration"
    end
  end

  # ---------------------------------------------------------------------------
  # Toggle integration
  # ---------------------------------------------------------------------------

  describe "toggle integration" do
    setup %{user: user} do
      {:ok, integration: insert(:telegram_integration, user: user, is_active: true)}
    end

    test "pauses an active integration and confirms via flash and DB", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("#telegram-toggle-#{integration.id}") |> render_click()

      assert render(view) =~ "Integration status updated"

      {:ok, refreshed} = Telegram.get_integration(integration.id, user.id)
      refute refreshed.is_active
    end
  end

  # ---------------------------------------------------------------------------
  # Delete integration
  # ---------------------------------------------------------------------------

  describe "delete integration" do
    setup %{user: user} do
      {:ok, integration: insert(:telegram_integration, user: user)}
    end

    test "deletes integration after confirming in the modal", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button[title='Delete']") |> render_click()
      assert render(view) =~ "Delete Telegram Integration?"

      view |> element("#delete-telegram-modal button", "Delete Integration") |> render_click()

      assert render(view) =~ "Integration deleted"
      assert render(view) =~ "No Telegram Integrations"
      assert {:error, _reason} = Telegram.get_integration(integration.id, user.id)
    end

    test "cancels deletion and leaves integration intact", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button[title='Delete']") |> render_click()
      view |> element("#delete-telegram-modal button", "Cancel") |> render_click()

      refute render(view) =~ "Integration deleted"
      assert {:ok, _integration} = Telegram.get_integration(integration.id, user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Delivery logs
  # ---------------------------------------------------------------------------

  describe "delivery logs" do
    setup %{user: user} do
      integration = insert(:telegram_integration, user: user)

      insert(:telegram_delivery,
        integration: integration,
        event_type: "meeting.created",
        response_status: 200
      )

      {:ok, integration: integration}
    end

    test "opens delivery logs modal showing statistics", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Logs") |> render_click()
      html = render(view)

      assert html =~ "Total"
      assert html =~ "Success"
    end
  end

  # ---------------------------------------------------------------------------
  # Feature access enforcement
  # ---------------------------------------------------------------------------

  describe "feature access enforcement" do
    test "shows plan upgrade message when access is denied (shared-bot create)", %{conn: conn} do
      ConfigTestHelpers.setup_config(:tymeslot,
        telegram_shared_bot: true,
        feature_access_checker: __MODULE__.InsufficientPlanChecker
      )

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()

      assert render(view) =~ "Pro plans"
    end
  end

  # ---------------------------------------------------------------------------
  # Shared-bot mode wizard
  # ---------------------------------------------------------------------------

  describe "shared-bot mode wizard" do
    setup do
      ConfigTestHelpers.setup_config(:tymeslot, telegram_shared_bot: true)
      :ok
    end

    test "shows the Connect Telegram wizard on form open", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()
      html = render(view)

      assert html =~ "Connect Telegram"
      assert html =~ "Open in Telegram"
    end

    test "closing the form without linking deletes the stub integration", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()
      assert length(Telegram.list_integrations(user.id)) == 1

      view |> element("button", "Close") |> render_click()

      assert Telegram.list_integrations(user.id) == []
    end

    test "shows Link Expired state when the timer message arrives", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()
      [stub] = Telegram.list_integrations(user.id)

      send(view.pid, {:telegram_link_expired, stub.id})

      eventually(fn ->
        html = render(view)
        assert html =~ "Link Expired"
        assert html =~ "Generate New Link"
      end)
    end

    test "advances the wizard to step 2 when the Telegram account is linked", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_telegram_tab(view)

      view |> element("button", "Add Telegram Account") |> render_click()
      [stub] = Telegram.list_integrations(user.id)

      send(view.pid, {:telegram_linked, stub.id, "987654321"})

      eventually(fn ->
        html = render(view)
        refute html =~ "Connect Telegram"
        assert html =~ "Integration Details"
      end)
    end
  end
end

defmodule TymeslotWeb.Dashboard.Automation.TelegramEventHandlersTest.InsufficientPlanChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: :ok | {:error, :insufficient_plan}
  def check_access(_user_id, :automations_allowed), do: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: :ok
end
