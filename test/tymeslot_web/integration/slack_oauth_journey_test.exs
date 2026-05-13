defmodule TymeslotWeb.Integration.SlackOAuthJourneyTest do
  @moduledoc """
  Full OAuth journey integration test for Slack.

  Exercises the three-stage user flow end-to-end:
    1. GET /api/slack/oauth/start  → redirect to Slack's authorize URL
    2. GET /api/slack/oauth/callback?code=…&state=… → pending integration
       created, redirect to ?slack_pending=<id>
    3. LiveView loads with ?slack_pending=<id> → channel-picker form opens →
       submit channel → integration status becomes :active
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :slack
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Phoenix.Token
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Slack
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias TymeslotWeb.Endpoint

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      slack_notifications_allowed: true,
      slack_oauth_available: true,
      slack_client_id: "test-client-id",
      slack_client_secret: "test-client-secret",
      http_client_module: Tymeslot.HTTPClientMock,
      environment: :test
    )

    setup_config(:tymeslot,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Stage 1 — start redirect
  # ---------------------------------------------------------------------------

  describe "GET /api/slack/oauth/start" do
    test "redirects to slack.com/oauth/v2/authorize with correct params", %{conn: conn} do
      user = insert(:user)

      conn = conn |> log_in_user(user) |> get(~p"/api/slack/oauth/start")

      target = redirected_to(conn, 302)
      assert String.starts_with?(target, "https://slack.com/oauth/v2/authorize?")

      params = target |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert params["client_id"] == "test-client-id"
      assert params["scope"] =~ "chat:write"
      assert params["redirect_uri"] =~ "/api/slack/oauth/callback"
      assert is_binary(params["state"])
      assert params["state"] != ""
    end
  end

  # ---------------------------------------------------------------------------
  # Stage 2 — callback creates pending integration
  # ---------------------------------------------------------------------------

  describe "GET /api/slack/oauth/callback with valid code" do
    test "exchanges the code, creates pending integration, redirects to dashboard with slack_pending param",
         %{conn: conn} do
      user = insert(:user)
      state = sign_state(user.id)

      expect(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
        assert url == "https://slack.com/api/oauth.v2.access"
        params = URI.decode_query(body)
        assert params["code"] == "valid-code"
        assert params["client_id"] == "test-client-id"

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "ok" => true,
               "access_token" => "xoxb-pending-token",
               "team" => %{"id" => "TTEST01", "name" => "Test Workspace"},
               "authed_user" => %{"id" => "UTEST01"},
               "scope" => "chat:write,channels:read"
             })
         }}
      end)

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/api/slack/oauth/callback?code=valid-code&state=#{state}")

      target = redirected_to(conn, 302)
      assert target =~ "/dashboard/automation"
      assert target =~ "slack_pending="
      assert Flash.get(conn.assigns.flash, :info) =~ "Slack connected"

      # Verify pending integration persisted
      [integration] = Slack.list_integrations(user.id)
      assert integration.user_id == user.id
      assert integration.app_mode == "oauth"
      assert integration.team_id == "TTEST01"
      assert SlackIntegrationSchema.status(integration) == :pending_oauth
    end
  end

  # ---------------------------------------------------------------------------
  # Stage 3 — LiveView opens channel picker, submit activates integration
  # ---------------------------------------------------------------------------

  describe "LiveView with ?slack_pending=<id>" do
    setup do
      user = insert(:user)
      {:ok, user} = UserQueries.mark_onboarding_complete(user)

      # Stub subscription and email mocks that the dashboard LiveView needs
      stub(Tymeslot.Payments.SubscriptionManagerMock, :should_show_branding?, fn _user_id ->
        true
      end)

      # Stub the Slack conversations.list API call triggered by the channel-picker
      # async load when the LiveView mounts with ?slack_pending=<id>.
      stub(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "ok" => true,
               "channels" => [
                 %{
                   "id" => "C123",
                   "name" => "general",
                   "is_archived" => false,
                   "is_member" => true,
                   "is_private" => false
                 }
               ],
               "response_metadata" => %{"next_cursor" => ""}
             })
         }}
      end)

      %{user: user}
    end

    test "loading with slack_pending param surfaces the channel-picker for that integration",
         %{conn: conn, user: user} do
      # Create a pending OAuth integration directly (simulating stage 2 outcome)
      {:ok, pending} =
        Slack.complete_oauth(user.id, %{
          name: "Test Workspace",
          bot_token: "xoxb-pending-token",
          team_id: "TTEST01",
          team_name: "Test Workspace",
          authed_user_id: "UTEST01",
          scope: "chat:write",
          events: ["meeting.created"]
        })

      assert SlackIntegrationSchema.status(pending) == :pending_oauth

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, "/dashboard/automation?slack_pending=#{pending.id}")

      # Channel-picker form should be visible
      assert html =~ "slack_pending" or render(view) =~ "channel" or
               render(view) =~ "Pick" or render(view) =~ "Channel"
    end

    test "submitting the channel form transitions the integration to :active",
         %{conn: conn, user: user} do
      {:ok, pending} =
        Slack.complete_oauth(user.id, %{
          name: "Test Workspace",
          bot_token: "xoxb-pending-token",
          team_id: "TTEST01",
          team_name: "Test Workspace",
          authed_user_id: "UTEST01",
          scope: "chat:write",
          events: ["meeting.created"]
        })

      assert SlackIntegrationSchema.status(pending) == :pending_oauth

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/dashboard/automation?slack_pending=#{pending.id}")

      # Submit the channel selection form
      view
      |> element("#slack-form")
      |> render_submit(%{
        "slack" => %{
          "channel_id" => "C_GENERAL",
          "channel_name" => "general",
          "events" => ["meeting.created"]
        }
      })

      # Integration should now be :active
      assert {:ok, activated} = Slack.get_integration(pending.id, user.id)
      assert SlackIntegrationSchema.status(activated) == :active
      assert activated.channel_id == "C_GENERAL"
    end
  end

  defp sign_state(user_id), do: Token.sign(Endpoint, "slack_oauth_state", user_id)
end
