defmodule Tymeslot.Integrations.Video.Teams.TeamsOAuthHelperTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias ExUnit.CaptureLog
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper
  import Mox

  setup :verify_on_exit!

  setup do
    # Teams helper reuses Outlook config in the code
    Application.put_env(:tymeslot, :outlook_oauth,
      client_id: "teams-id",
      client_secret: "teams-secret",
      state_secret: "teams-state"
    )

    :ok
  end

  describe "authorization_url/2" do
    test "generates valid Teams OAuth URL" do
      url = TeamsOAuthHelper.authorization_url(1, "http://uri")
      assert url =~ "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
      assert url =~ "client_id=teams-id"
      assert url =~ "scope=https%3A%2F%2Fgraph.microsoft.com%2FCalendars.ReadWrite"
    end
  end

  describe "exchange_code_for_tokens/2" do
    test "exchanges the code and reads the Microsoft account" do
      %{resp_body: resp_body} = oauth_test_data()

      profile_body =
        Jason.encode!(%{
          "id" => "microsoft-user-123",
          "displayName" => "Microsoft User"
        })

      # Mock token exchange
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      # Mock profile fetch
      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url == "https://graph.microsoft.com/v1.0/me"
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:ok, tokens} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri")

      assert tokens.access_token == "at-123"
      assert tokens.teams_user_id == "microsoft-user-123"
      assert tokens.tenant_id == "common"
    end

    # A profile request Graph keeps failing is retried, and the error names
    # the last status rather than only that the attempts ran out.
    test "retries a failing profile request and reports its last status" do
      %{resp_body: resp_body} = oauth_test_data()

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, 3, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 502, body: "bad gateway"}}
      end)

      assert {:error, "Failed to fetch user profile: HTTP 502"} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri",
                 profile_retry: [initial_delay: 0]
               )
    end

    # Graph names how long to wait; waiting less only earns another 429.
    test "retries a rate-limited profile request after the wait Graph names" do
      %{resp_body: resp_body} = oauth_test_data()
      profile_body = Jason.encode!(%{"id" => "teams-user-429", "mail" => "alice@example.com"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 429, headers: %{"retry-after" => ["1"]}, body: ""}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      # The usual backoff here is no wait; the named second, capped at 60 ms.
      {elapsed_us, result} =
        :timer.tc(fn ->
          CaptureLog.with_log(fn ->
            TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri",
              profile_retry: [initial_delay: 0, max_delay: 60, jitter: 0.0]
            )
          end)
        end)

      assert {{:ok, tokens}, _log} = result
      assert tokens.provider_account_id == "teams-user-429"
      assert div(elapsed_us, 1_000) >= 60
    end

    # The owner is waiting on the callback page.
    test "fails at once when Graph asks for a longer wait than a page can hold" do
      %{resp_body: resp_body} = oauth_test_data()

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, 1, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 429, headers: %{"retry-after" => ["30"]}, body: ""}}
      end)

      {elapsed_us, {result, _log}} =
        :timer.tc(fn ->
          CaptureLog.with_log(fn ->
            TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri")
          end)
        end)

      assert result == {:error, :provider_rate_limited}
      assert div(elapsed_us, 1_000) < 1_000
    end

    # Graph refused the token: asking again cannot change that.
    test "does not retry a profile request Graph refuses" do
      %{resp_body: resp_body} = oauth_test_data()

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, 1, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: "no"}}
      end)

      assert {:error, "Failed to fetch user profile: HTTP 401"} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri")
    end

    test "extracts tenant_id from id_token claims" do
      # Mock id_token with tid claim
      header = Base.url_encode64(Jason.encode!(%{alg: "RS256"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{tid: "real-tenant-id"}), padding: false)
      id_token = "#{header}.#{payload}.sig"

      resp_body =
        Jason.encode!(%{
          "access_token" => "at-123",
          "id_token" => id_token,
          "expires_in" => 3600,
          "scope" => "Calendars.ReadWrite"
        })

      profile_body =
        Jason.encode!(%{
          "id" => "microsoft-user-123"
        })

      # Mock token exchange
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      # Mock profile fetch
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:ok, tokens} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri")

      assert tokens.tenant_id == "real-tenant-id"
    end

    test "fails if profile is missing id" do
      %{resp_body: resp_body} = oauth_test_data()

      profile_body = Jason.encode!(%{"displayName" => "Microsoft User"})

      # Mock token exchange
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      # Mock profile fetch
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:error, "Microsoft profile missing unique ID"} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri")
    end

    test "retries profile fetch on transient error" do
      %{resp_body: resp_body} = oauth_test_data()

      profile_body =
        Jason.encode!(%{
          "id" => "microsoft-user-123"
        })

      # Mock token exchange
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      # Mock profile fetch: failure then success
      Tymeslot.HTTPClientMock
      |> expect(:get, fn _url, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)
      |> expect(:get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:ok, tokens} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri")

      assert tokens.teams_user_id == "microsoft-user-123"
    end
  end

  describe "refresh_access_token/2" do
    test "refreshes token successfully" do
      resp_body =
        Jason.encode!(%{
          "access_token" => "new-at",
          "expires_in" => 3600
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:ok, tokens} = TeamsOAuthHelper.refresh_access_token("old-rt")
      assert tokens.access_token == "new-at"
    end

    test "surfaces OAuth error type on 400 with invalid_client body" do
      resp_body = Jason.encode!(%{"error" => "invalid_client"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 400, body: resp_body}}
      end)

      assert {:error, msg} = TeamsOAuthHelper.refresh_access_token("bad-rt")
      assert msg == "Token refresh failed: invalid_client"
    end

    test "returns generic message for 5xx responses even with OAuth-shaped body" do
      resp_body = Jason.encode!(%{"error" => "access_denied"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 503, body: resp_body}}
      end)

      assert {:error, msg} = TeamsOAuthHelper.refresh_access_token("rt")
      assert msg == "Token refresh failed: HTTP 503 (see logs for details)"
      refute msg =~ "access_denied"
    end
  end

  describe "validate_token/1" do
    test "returns :valid when token is not expired" do
      future = DateTime.add(DateTime.utc_now(), 1, :hour)
      assert {:ok, :valid} = TeamsOAuthHelper.validate_token(%{token_expires_at: future})
    end

    test "returns :needs_refresh when token is close to expiry" do
      soon = DateTime.add(DateTime.utc_now(), 2, :minute)
      assert {:ok, :needs_refresh} = TeamsOAuthHelper.validate_token(%{token_expires_at: soon})
    end

    # A token whose lifetime was never stored is renewed, not refused.
    test "asks for a refresh when the expiry is unknown" do
      assert {:ok, :needs_refresh} = TeamsOAuthHelper.validate_token(%{})
      assert {:ok, :needs_refresh} = TeamsOAuthHelper.validate_token(%{token_expires_at: nil})
    end
  end

  describe "PKCE" do
    @pkce [pkce: %{nonce: "flow-nonce", code_challenge: "flow-challenge"}]

    test "the authorisation URL carries the flow's challenge, and its state the nonce" do
      query =
        TeamsOAuthHelper.authorization_url(123, "http://cb", @pkce)
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert query["code_challenge"] == "flow-challenge"
      assert query["code_challenge_method"] == "S256"
      assert {:ok, %{nonce: "flow-nonce"}} = State.validate(query["state"], "teams-state")
    end

    test "the code exchange presents the flow's verifier" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
        assert URI.decode_query(body)["code_verifier"] == "flow-verifier"
        {:ok, %{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      assert {:error, _reason} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://cb",
                 code_verifier: "flow-verifier"
               )
    end
  end

  defp oauth_test_data do
    resp_body =
      Jason.encode!(%{
        "access_token" => "at-123",
        "refresh_token" => "rt-123",
        "expires_in" => 3600,
        "scope" => "Calendars.ReadWrite"
      })

    %{resp_body: resp_body}
  end
end
