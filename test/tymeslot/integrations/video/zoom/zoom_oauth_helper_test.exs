defmodule Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Common.OAuth.State
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

      # Rescheduling needs `meeting:update:meeting`, which the Marketplace app
      # is not configured for. Zoom does not reject a request naming it — the
      # scope is dropped and the rest consented to — so asking would be
      # silently useless, while telling the rest of the system the scope is
      # obtainable and switching on "reconnect to fix this" prompts that cannot
      # fix it. This assertion keeps it out until the app is configured.
      refute query["scope"] =~ "meeting:update:meeting"

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

  describe "exchange_code_for_tokens/3" do
    test "exchanges code, fetches profile, and returns merged tokens" do
      %{user_id: user_id, state: state, resp_body: resp_body} = oauth_test_data()

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
               ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb", state)

      assert tokens.access_token == "at-123"
      assert tokens.refresh_token == "rt-123"
      assert tokens.user_id == user_id
      assert tokens.provider_account_id == "zoom-user-123"
      assert tokens.provider_account_email == "alice@example.com"
    end

    test "rejects invalid state without making HTTP calls" do
      assert {:error, _reason} =
               ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb", "bogus")
    end

    test "fails when profile is missing id" do
      %{state: state, resp_body: resp_body} = oauth_test_data()
      profile_body = Jason.encode!(%{"email" => "alice@example.com"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:error, "Zoom profile missing unique ID"} =
               ZoomOAuthHelper.exchange_code_for_tokens("code", "https://example.com/cb", state)
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

    test "returns error when expiration info is missing" do
      assert {:error, _reason} = ZoomOAuthHelper.validate_token(%{})
    end
  end

  defp oauth_test_data do
    user_id = 123
    state = State.generate(user_id, "zoom-state-secret")

    resp_body =
      Jason.encode!(%{
        "access_token" => "at-123",
        "refresh_token" => "rt-123",
        "expires_in" => 3600,
        "scope" => "meeting:write:meeting meeting:read:meeting user:read:user"
      })

    %{user_id: user_id, state: state, resp_body: resp_body}
  end
end
