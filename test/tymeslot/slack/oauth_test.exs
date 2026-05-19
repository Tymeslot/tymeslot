defmodule Tymeslot.Slack.OAuthTest do
  use ExUnit.Case, async: false

  @moduletag :slack
  @moduletag :unit

  import Mox

  alias Phoenix.Token
  alias Tymeslot.Slack.OAuth
  alias TymeslotWeb.Endpoint

  setup :verify_on_exit!

  setup do
    Application.put_env(:tymeslot, :http_client_module, Tymeslot.HTTPClientMock)
    Application.put_env(:tymeslot, :slack_client_id, "slack-test-client-id")
    Application.put_env(:tymeslot, :slack_client_secret, "slack-test-client-secret")

    on_exit(fn ->
      Application.delete_env(:tymeslot, :http_client_module)
      Application.delete_env(:tymeslot, :slack_client_id)
      Application.delete_env(:tymeslot, :slack_client_secret)
    end)

    :ok
  end

  describe "authorize_url/2" do
    test "embeds client_id, scope, redirect_uri and a signed state token" do
      url = OAuth.authorize_url(42, "https://example.test/cb")

      assert String.starts_with?(url, "https://slack.com/oauth/v2/authorize?")

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["client_id"] == "slack-test-client-id"
      assert params["redirect_uri"] == "https://example.test/cb"
      assert params["scope"] =~ "chat:write"
      assert params["scope"] =~ "channels:read"
      assert is_binary(params["state"])
      assert params["state"] != ""
    end

    test "raises when slack_client_id is not configured" do
      Application.delete_env(:tymeslot, :slack_client_id)

      assert_raise RuntimeError, ~r/missing slack_client_id/, fn ->
        OAuth.authorize_url(1, "https://example.test/cb")
      end
    end
  end

  describe "verify_state/1" do
    test "round-trips a state token signed by authorize_url/2" do
      url = OAuth.authorize_url(7, "https://example.test/cb")

      state =
        url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

      assert {:ok, 7} = OAuth.verify_state(state)
    end

    test "returns :invalid_state for malformed input" do
      assert {:error, :invalid_state} = OAuth.verify_state("not-a-real-token")
    end

    test "returns :expired_state for a token past max_age" do
      # Phoenix.Token max_age compares against the token's signed_at timestamp.
      # Sign one manually with a backdated timestamp so we don't need to sleep.
      backdated_signed_at = System.system_time(:second) - 3_600

      state =
        Token.sign(
          Endpoint,
          "slack_oauth_state",
          99,
          signed_at: backdated_signed_at
        )

      assert {:error, :expired_state} = OAuth.verify_state(state)
    end
  end

  describe "exchange_code/2" do
    test "calls Slack.API and returns the normalised install map on success" do
      expect(Tymeslot.HTTPClientMock, :post, fn url, body, headers, _opts ->
        assert url == "https://slack.com/api/oauth.v2.access"
        assert {"content-type", "application/x-www-form-urlencoded"} in headers
        params = URI.decode_query(body)
        assert params["client_id"] == "slack-test-client-id"
        assert params["client_secret"] == "slack-test-client-secret"
        assert params["code"] == "the-code"
        assert params["redirect_uri"] == "https://example.test/cb"

        {:ok,
         %{
           status: 200,
           body:
             ~s({"ok":true,"access_token":"xoxb-installed","team":{"id":"T7","name":"Acme"},"authed_user":{"id":"U7"},"scope":"chat:write,channels:read"})
         }}
      end)

      assert {:ok, install} = OAuth.exchange_code("the-code", "https://example.test/cb")

      assert install == %{
               bot_token: "xoxb-installed",
               team_id: "T7",
               team_name: "Acme",
               authed_user_id: "U7",
               scope: "chat:write,channels:read"
             }
    end

    test "propagates a Slack API error" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"invalid_code"})}}
      end)

      assert {:error, {:slack_error, "invalid_code", %{"ok" => false}}} =
               OAuth.exchange_code("bad", "https://example.test/cb")
    end

    test "returns :missing_bot_token when Slack response lacks access_token" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        # Simulates a user-token-only app where no bot token is granted
        {:ok,
         %{
           status: 200,
           body:
             ~s({"ok":true,"authed_user":{"id":"U1","access_token":"xoxp-user-token"},"team":{"id":"T1","name":"Test"},"scope":"identify"})
         }}
      end)

      assert {:error, :missing_bot_token} =
               OAuth.exchange_code("user-only-code", "https://example.test/cb")
    end

    test "raises when slack_client_secret is not configured" do
      Application.delete_env(:tymeslot, :slack_client_secret)

      assert_raise RuntimeError, ~r/missing slack_client_secret/, fn ->
        OAuth.exchange_code("c", "https://example.test/cb")
      end
    end
  end
end
