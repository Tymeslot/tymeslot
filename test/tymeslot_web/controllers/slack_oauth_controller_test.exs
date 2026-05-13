defmodule TymeslotWeb.SlackOAuthControllerTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :slack
  @moduletag :auth

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Phoenix.Token
  alias Tymeslot.Repo
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias TymeslotWeb.Endpoint

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      slack_notifications_allowed: true,
      slack_client_id: "slack-test-client-id",
      slack_client_secret: "slack-test-client-secret",
      http_client_module: Tymeslot.HTTPClientMock,
      environment: :test
    )

    :ok
  end

  describe "GET /api/slack/oauth/start" do
    test "redirects to slack.com/oauth/v2/authorize with the expected params", %{conn: conn} do
      user = insert(:user)
      conn = conn |> log_in_user(user) |> get(~p"/api/slack/oauth/start")

      target = redirected_to(conn, 302)
      assert String.starts_with?(target, "https://slack.com/oauth/v2/authorize?")

      params = target |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert params["client_id"] == "slack-test-client-id"
      assert params["scope"] =~ "chat:write"
      assert params["redirect_uri"] =~ "/api/slack/oauth/callback"
      assert is_binary(params["state"])
      assert params["state"] != ""
    end

    test "redirects unauthenticated requests to the login page", %{conn: conn} do
      conn = get(conn, ~p"/api/slack/oauth/start")
      assert redirected_to(conn) == "/auth/login"
    end
  end

  describe "GET /api/slack/oauth/callback — success" do
    test "exchanges the code, creates a pending integration, redirects to dashboard",
         %{conn: conn} do
      user = insert(:user)
      state = sign_state(user.id)

      expect(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
        assert url == "https://slack.com/api/oauth.v2.access"
        params = URI.decode_query(body)
        assert params["code"] == "abc123"
        assert params["redirect_uri"] =~ "/api/slack/oauth/callback"

        {:ok,
         %{
           status: 200,
           body:
             ~s({"ok":true,"access_token":"xoxb-real","team":{"id":"T7","name":"Acme"},"authed_user":{"id":"U7"},"scope":"chat:write"})
         }}
      end)

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/api/slack/oauth/callback?code=abc123&state=#{state}")

      target = redirected_to(conn, 302)
      assert target =~ "/dashboard/automation"
      assert target =~ "slack_pending="
      assert Flash.get(conn.assigns.flash, :info) =~ "Slack connected"

      [integration] = Repo.all(SlackIntegrationSchema)
      assert integration.user_id == user.id
      assert integration.app_mode == "oauth"
      assert integration.team_id == "T7"
      assert integration.team_name == "Acme"
      assert SlackIntegrationSchema.status(integration) == :pending_oauth
      assert SlackIntegrationSchema.bot_token(integration) == "xoxb-real"
    end
  end

  describe "GET /api/slack/oauth/callback — error param" do
    test "shows a cancellation flash and redirects to dashboard", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/api/slack/oauth/callback?error=access_denied")

      assert redirected_to(conn) == "/dashboard/automation"
      assert Flash.get(conn.assigns.flash, :error) =~ "cancelled"
      assert Repo.all(SlackIntegrationSchema) == []
    end
  end

  describe "GET /api/slack/oauth/callback — invalid state" do
    test "shows an invalid-state flash for a malformed token", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/api/slack/oauth/callback?code=c&state=garbage")

      assert redirected_to(conn) == "/dashboard/automation"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid"
      assert Repo.all(SlackIntegrationSchema) == []
    end

    test "shows an expired-state flash for an old token", %{conn: conn} do
      user = insert(:user)

      expired =
        Token.sign(
          Endpoint,
          "slack_oauth_state",
          user.id,
          signed_at: System.system_time(:second) - 3_600
        )

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/api/slack/oauth/callback?code=c&state=#{expired}")

      assert redirected_to(conn) == "/dashboard/automation"
      assert Flash.get(conn.assigns.flash, :error) =~ "expired"
      assert Repo.all(SlackIntegrationSchema) == []
    end
  end

  describe "GET /api/slack/oauth/callback — user mismatch" do
    test "rejects a state that was signed for a different user", %{conn: conn} do
      user = insert(:user)
      other_user = insert(:user)
      foreign_state = sign_state(other_user.id)

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/api/slack/oauth/callback?code=c&state=#{foreign_state}")

      assert redirected_to(conn) == "/dashboard/automation"
      assert Flash.get(conn.assigns.flash, :error) =~ "did not match your session"
      assert Repo.all(SlackIntegrationSchema) == []
    end
  end

  defp sign_state(user_id) do
    Token.sign(Endpoint, "slack_oauth_state", user_id)
  end
end
