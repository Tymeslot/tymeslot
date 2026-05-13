defmodule TymeslotWeb.Dashboard.Automation.SlackEventHandlersTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :slack
  @moduletag :live
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Slack

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      slack_notifications_allowed: true,
      slack_oauth_available: false,
      slack_client_id: nil,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  # Navigates to /dashboard/automation and switches to the Slack tab.
  defp open_slack_tab(view) do
    view |> element("button", "Slack") |> render_click()
    render(view)
  end

  # ---------------------------------------------------------------------------
  # Empty state
  # ---------------------------------------------------------------------------

  describe "empty state" do
    test "renders the no-integrations card with the webhook-URL CTA when OAuth is disabled",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_slack_tab(view)

      assert html =~ "No Slack Integrations"
      assert html =~ "Add Slack via Webhook URL"
      refute html =~ "Add to Slack"
    end

    test "exposes the Add to Slack link when OAuth is configured", %{conn: conn} do
      ConfigTestHelpers.setup_config(:tymeslot,
        slack_oauth_available: true,
        slack_client_id: "test-client-id"
      )

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_slack_tab(view)

      assert html =~ "Add to Slack"
      assert html =~ "/api/slack/oauth/start"
    end
  end

  # ---------------------------------------------------------------------------
  # Webhook URL form
  # ---------------------------------------------------------------------------

  describe "webhook URL form" do
    test "opens the webhook URL form when the secondary CTA is clicked",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Add Slack via Webhook URL") |> render_click()
      html = render(view)

      assert html =~ "Slack Webhook URL"
      assert html =~ "hooks.slack.com"
    end

    test "creates an integration on successful submit and shows it in the list",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Add Slack via Webhook URL") |> render_click()

      view
      |> form("#slack-form", %{
        "slack" => %{
          "name" => "Acme Channel",
          "webhook_url" => "https://hooks.slack.com/services/TABC/BABC/secrettoken",
          "webhook_channel_hint" => "#bookings",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Slack integration created"
      assert html =~ "Acme Channel"
      assert [%{name: "Acme Channel"}] = Slack.list_integrations(user.id)
    end

    test "keeps the form open and surfaces an error when the URL is malformed",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Add Slack via Webhook URL") |> render_click()

      view
      |> form("#slack-form", %{
        "slack" => %{
          "name" => "Bad URL",
          "webhook_url" => "https://example.com/not-slack",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "hooks.slack.com"
      assert Slack.list_integrations(user.id) == []
    end

    test "closes the form and returns to the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Add Slack via Webhook URL") |> render_click()
      assert render(view) =~ "Slack Webhook URL"

      view |> element("button", "Close") |> render_click()
      assert render(view) =~ "No Slack Integrations"
    end
  end

  # ---------------------------------------------------------------------------
  # Toggle integration
  # ---------------------------------------------------------------------------

  describe "toggle integration" do
    setup %{user: user} do
      integration =
        insert(:slack_integration,
          user: user,
          app_mode: "webhook_url",
          webhook_url_encrypted:
            Tymeslot.Security.Encryption.encrypt(
              "https://hooks.slack.com/services/TABC/BABC/secrettoken"
            ),
          bot_token_encrypted: nil,
          team_id: nil,
          channel_id: nil,
          channel_name: nil,
          is_active: true
        )

      {:ok, integration: integration}
    end

    test "pauses an active integration and confirms via flash and DB", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("#slack-toggle-#{integration.id}") |> render_click()

      assert render(view) =~ "Integration status updated"

      {:ok, refreshed} = Slack.get_integration(integration.id, user.id)
      refute refreshed.is_active
    end
  end

  # ---------------------------------------------------------------------------
  # Delete integration
  # ---------------------------------------------------------------------------

  describe "delete integration" do
    setup %{user: user} do
      integration =
        insert(:slack_integration,
          user: user,
          app_mode: "webhook_url",
          webhook_url_encrypted:
            Tymeslot.Security.Encryption.encrypt(
              "https://hooks.slack.com/services/TABC/BABC/secrettoken"
            ),
          bot_token_encrypted: nil,
          team_id: nil,
          channel_id: nil,
          channel_name: nil
        )

      {:ok, integration: integration}
    end

    test "deletes the integration after confirming in the modal", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button[title='Delete']") |> render_click()
      assert render(view) =~ "Delete Slack Integration?"

      view |> element("#delete-slack-modal button", "Delete Integration") |> render_click()

      assert render(view) =~ "Slack integration deleted"
      assert render(view) =~ "No Slack Integrations"
      assert {:error, _reason} = Slack.get_integration(integration.id, user.id)
    end

    test "cancels deletion and leaves integration intact", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button[title='Delete']") |> render_click()
      view |> element("#delete-slack-modal button", "Cancel") |> render_click()

      refute render(view) =~ "Slack integration deleted"
      assert {:ok, _integration} = Slack.get_integration(integration.id, user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Delivery logs
  # ---------------------------------------------------------------------------

  describe "delivery logs" do
    setup %{user: user} do
      integration =
        insert(:slack_integration,
          user: user,
          app_mode: "webhook_url",
          webhook_url_encrypted:
            Tymeslot.Security.Encryption.encrypt(
              "https://hooks.slack.com/services/TABC/BABC/secrettoken"
            ),
          bot_token_encrypted: nil,
          team_id: nil,
          channel_id: nil,
          channel_name: nil
        )

      insert(:slack_delivery,
        integration: integration,
        event_type: "meeting.created",
        response_status: 200
      )

      {:ok, integration: integration}
    end

    test "opens the delivery-logs modal showing statistics", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Logs") |> render_click()
      html = render(view)

      assert html =~ "Total"
      assert html =~ "Success"
    end
  end

  # ---------------------------------------------------------------------------
  # Pending OAuth deep link
  # ---------------------------------------------------------------------------

  describe "?slack_pending deep link" do
    test "opens the channel-picker form for the matching integration", %{
      conn: conn,
      user: user
    } do
      ConfigTestHelpers.setup_config(:tymeslot,
        slack_oauth_available: true,
        slack_client_id: "test-client-id"
      )

      pending =
        insert(:slack_integration,
          user: user,
          app_mode: "oauth",
          channel_id: nil,
          channel_name: nil
        )

      {:ok, view, _html} = live(conn, "/dashboard/automation?slack_pending=#{pending.id}")
      html = render(view)

      assert html =~ "Finish Slack setup"
      assert html =~ "Pick a channel"
    end
  end

  # ---------------------------------------------------------------------------
  # Feature access enforcement
  # ---------------------------------------------------------------------------

  describe "feature access enforcement" do
    test "blocks integration creation and surfaces a plan upgrade flash",
         %{conn: conn, user: user} do
      ConfigTestHelpers.setup_config(:tymeslot,
        feature_access_checker:
          TymeslotWeb.Dashboard.Automation.SlackEventHandlersTest.InsufficientPlanChecker
      )

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Add Slack via Webhook URL") |> render_click()

      view
      |> form("#slack-form", %{
        "slack" => %{
          "name" => "Blocked",
          "webhook_url" => "https://hooks.slack.com/services/TABC/BABC/secrettoken",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      assert render(view) =~ "Pro plans"
      assert Slack.list_integrations(user.id) == []
    end
  end
end

defmodule TymeslotWeb.Dashboard.Automation.SlackEventHandlersTest.InsufficientPlanChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: :ok | {:error, :insufficient_plan}
  def check_access(_user_id, :automations_allowed), do: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: :ok
end
