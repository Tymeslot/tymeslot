defmodule Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox

  alias ExUnit.CaptureLog
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tymeslot, :zoom_oauth)

    Application.put_env(:tymeslot, :zoom_oauth,
      client_id: "zoom-client-id",
      client_secret: "zoom-client-secret",
      state_secret: "zoom-state-secret"
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, :zoom_oauth)
      else
        Application.put_env(:tymeslot, :zoom_oauth, original)
      end
    end)

    :ok
  end

  describe "authorization_url/2" do
    test "produces a Zoom authorize URL with required params" do
      url = ZoomOAuthHelper.authorization_url(123, "https://example.com/cb")

      uri = URI.parse(url)
      assert uri.host == "zoom.us"
      assert uri.path == "/oauth/authorize"

      query = URI.decode_query(uri.query)
      assert query["client_id"] == "zoom-client-id"
      assert query["redirect_uri"] == "https://example.com/cb"
      assert query["response_type"] == "code"
      assert query["scope"] =~ "meeting:write:meeting"
      # Cancelling needs its own granular scope; without it Zoom rejects every
      # delete with code 4711.
      assert query["scope"] =~ "meeting:delete:meeting"

      # Rescheduling needs its own granular scope too.
      assert query["scope"] =~ "meeting:update:meeting"

      # Signed state: base64url payload and HMAC, separated by a dot.
      assert [_payload, _signature] = String.split(query["state"], ".")
    end
  end

  describe "authorization_url/3" do
    test "includes login_hint when supplied" do
      url =
        ZoomOAuthHelper.authorization_url(123, "https://example.com/cb",
          login_hint: "alice@example.com"
        )

      assert url =~ "login_hint=alice%40example.com"
    end

    test "embeds integration_id in signed state when supplied" do
      url =
        ZoomOAuthHelper.authorization_url(123, "https://example.com/cb", integration_id: 99)

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      {:ok, decoded} = State.validate(query["state"], "zoom-state-secret")
      assert decoded.user_id == 123
      assert decoded.integration_id == 99
    end
  end

  describe "exchange_code_for_tokens/2" do
    test "exchanges code, fetches profile, and returns merged tokens" do
      %{resp_body: resp_body} = oauth_test_data()

      profile_body =
        Jason.encode!(%{
          "id" => "zoom-user-123",
          "email" => "alice@example.com"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, _body, headers, _opts ->
        assert url == "https://zoom.us/oauth/token"

        assert {"Authorization", "Basic " <> _credentials} =
                 List.keyfind(headers, "Authorization", 0)

        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/users/me"
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:ok, tokens} =
               ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb")

      assert tokens.access_token == "at-123"
      assert tokens.refresh_token == "rt-123"
      assert tokens.provider_account_id == "zoom-user-123"
      assert tokens.provider_account_email == "alice@example.com"
    end

    # A profile request Zoom keeps failing is retried, and the error names the
    # last status rather than only that the attempts ran out.
    test "retries a failing profile request and reports its last status" do
      %{resp_body: resp_body} = oauth_test_data()

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, 3, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 503, body: "busy"}}
      end)

      assert {:error, "Failed to fetch user profile: HTTP 503"} =
               ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb",
                 profile_retry: [initial_delay: 0]
               )
    end

    # Zoom names how long to wait; waiting less only earns another 429.
    test "retries a rate-limited profile request after the wait Zoom names" do
      %{resp_body: resp_body} = oauth_test_data()
      profile_body = Jason.encode!(%{"id" => "zoom-user-429", "email" => "alice@example.com"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
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
            ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb",
              profile_retry: [initial_delay: 0, max_delay: 60, jitter: 0.0]
            )
          end)
        end)

      assert {{:ok, tokens}, _log} = result
      assert tokens.provider_account_id == "zoom-user-429"
      assert div(elapsed_us, 1_000) >= 60
    end

    # The owner is waiting on the callback page.
    test "fails at once when Zoom asks for a longer wait than a page can hold" do
      %{resp_body: resp_body} = oauth_test_data()

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, 1, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 429, headers: %{"retry-after" => ["30"]}, body: ""}}
      end)

      {elapsed_us, {result, _log}} =
        :timer.tc(fn ->
          CaptureLog.with_log(fn ->
            ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb")
          end)
        end)

      assert result == {:error, :provider_rate_limited}
      assert div(elapsed_us, 1_000) < 1_000
    end

    test "does not retry a profile request Zoom refuses" do
      %{resp_body: resp_body} = oauth_test_data()

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, 1, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: "no"}}
      end)

      assert {:error, "Failed to fetch user profile: HTTP 401"} =
               ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb")
    end

    test "fails when profile is missing id" do
      %{resp_body: resp_body} = oauth_test_data()
      profile_body = Jason.encode!(%{"email" => "alice@example.com"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:error, "Zoom profile missing unique ID"} =
               ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb")
    end
  end

  describe "refresh_access_token/2" do
    test "refreshes token successfully using basic-auth headers" do
      resp_body =
        Jason.encode!(%{
          "access_token" => "new-at",
          "refresh_token" => "new-rt",
          "expires_in" => 3600,
          "scope" => "meeting:write:meeting"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, headers, _opts ->
        assert url == "https://zoom.us/oauth/token"
        assert body =~ "grant_type=refresh_token"
        assert body =~ "refresh_token=old-rt"
        assert {"Authorization", "Basic " <> _creds} = List.keyfind(headers, "Authorization", 0)
        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:ok, tokens} = ZoomOAuthHelper.refresh_access_token("old-rt")
      assert tokens.access_token == "new-at"
      assert tokens.refresh_token == "new-rt"
    end

    test "surfaces OAuth error type on 400 with invalid_grant body" do
      resp_body = Jason.encode!(%{"error" => "invalid_grant"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: resp_body}}
      end)

      assert {:error, msg} = ZoomOAuthHelper.refresh_access_token("revoked")
      assert msg == "Token refresh failed: invalid_grant"
    end
  end

  describe "validate_token/1" do
    test "returns :valid when token is not near expiry" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, :valid} = ZoomOAuthHelper.validate_token(%{token_expires_at: future})
    end

    test "returns :needs_refresh when token is near expiry" do
      soon = DateTime.add(DateTime.utc_now(), 60, :second)
      assert {:ok, :needs_refresh} = ZoomOAuthHelper.validate_token(%{token_expires_at: soon})
    end

    # A token whose lifetime was never stored is renewed, not refused.
    test "asks for a refresh when the expiry is unknown" do
      assert {:ok, :needs_refresh} = ZoomOAuthHelper.validate_token(%{})
      assert {:ok, :needs_refresh} = ZoomOAuthHelper.validate_token(%{token_expires_at: nil})
    end
  end

  describe "PKCE" do
    @pkce [pkce: %{nonce: "flow-nonce", code_challenge: "flow-challenge"}]

    test "the authorisation URL carries the flow's challenge, and its state the nonce" do
      query =
        ZoomOAuthHelper.authorization_url(123, "http://cb", @pkce)
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert query["code_challenge"] == "flow-challenge"
      assert query["code_challenge_method"] == "S256"
      assert {:ok, %{nonce: "flow-nonce"}} = State.validate(query["state"], "zoom-state-secret")
    end

    test "the code exchange presents the flow's verifier" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
        assert URI.decode_query(body)["code_verifier"] == "flow-verifier"
        {:ok, %{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      assert {:error, _reason} =
               ZoomOAuthHelper.exchange_code_for_tokens("code", "http://cb",
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
        "scope" => "meeting:write:meeting meeting:read:meeting user:read:user"
      })

    %{resp_body: resp_body}
  end

  describe "revoke_token/1" do
    test "a 400 saying the token is invalid counts as revoked" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{status: 400, body: %{"reason" => "Invalid token.", "status" => "failed"}}}
      end)

      assert ZoomOAuthHelper.revoke_token("gone") == :ok
    end

    test "a 400 for another reason stays a failure" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: %{"reason" => "Invalid client secret."}}}
      end)

      assert ZoomOAuthHelper.revoke_token("tok") == {:error, {:http_error, 400}}
    end

    test "a 400 with an unreadable body stays a failure" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: "<html>"}}
      end)

      assert ZoomOAuthHelper.revoke_token("tok") == {:error, {:http_error, 400}}
    end
  end
end
