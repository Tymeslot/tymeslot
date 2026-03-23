defmodule Tymeslot.Integrations.Google.GoogleOAuthHelperTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  import Mox

  setup :verify_on_exit!

  @client_id "test-client-id"
  @client_secret "test-client-secret"
  @state_secret "test-state-secret"

  setup do
    Application.put_env(:tymeslot, :google_oauth,
      client_id: @client_id,
      client_secret: @client_secret,
      state_secret: @state_secret
    )

    :ok
  end

  describe "authorization_url/4" do
    test "generates valid Google OAuth URL" do
      url = GoogleOAuthHelper.authorization_url(123, "http://localhost/callback", [:calendar])

      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth"
      assert url =~ "client_id=#{@client_id}"
      assert url =~ "redirect_uri=http%3A%2F%2Flocalhost%2Fcallback"
      assert url =~ "scope=openid+email+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar"
      assert url =~ "access_type=offline"
      assert url =~ "prompt=consent+select_account"
      assert url =~ "state="
    end

    test "handles multiple scopes" do
      url =
        GoogleOAuthHelper.authorization_url(123, "http://localhost/callback", [
          :calendar,
          :meet,
          "custom"
        ])

      assert url =~
               "scope=openid+email+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fmeetings.space.created+custom"
    end

    test "overrides options" do
      url =
        GoogleOAuthHelper.authorization_url(123, "http://localhost/callback", [:calendar],
          access_type: "online",
          prompt: "none"
        )

      assert url =~ "access_type=online"
      assert url =~ "prompt=none"
    end
  end

  describe "exchange_code_for_tokens/3" do
    test "exchanges code and validates state" do
      state = GoogleOAuthHelper.generate_state(123)

      resp_body =
        Jason.encode!(%{
          "access_token" => "at-123",
          "refresh_token" => "rt-123",
          "expires_in" => 3600,
          "scope" => "calendar"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post,
                                                   "https://oauth2.googleapis.com/token",
                                                   body,
                                                   _headers,
                                                   _opts ->
        params = URI.decode_query(body)
        assert params["code"] == "auth-code"
        assert params["client_id"] == @client_id
        assert params["client_secret"] == @client_secret
        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:ok, tokens} =
               GoogleOAuthHelper.exchange_code_for_tokens("auth-code", "http://callback", state)

      assert tokens.access_token == "at-123"
      assert tokens.user_id == 123
    end

    test "handles error from Google" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: "error_msg"}}
      end)

      assert {:error, msg} = GoogleOAuthHelper.exchange_code_for_tokens("code", "uri")
      assert msg =~ "HTTP 400"
    end
  end

  describe "refresh_access_token/2" do
    test "refreshes token successfully" do
      resp_body =
        Jason.encode!(%{
          "access_token" => "new-at",
          "expires_in" => 3600
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
        params = URI.decode_query(body)
        assert params["refresh_token"] == "old-rt"
        assert params["grant_type"] == "refresh_token"
        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:ok, tokens} = GoogleOAuthHelper.refresh_access_token("old-rt")
      assert tokens.access_token == "new-at"
    end
  end

  describe "validate_token_scope/2" do
    test "returns :ok for sufficient scopes" do
      resp_body =
        Jason.encode!(%{
          "scope" =>
            "https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/userinfo.email"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, headers, _opts ->
        assert url == "https://www.googleapis.com/oauth2/v1/tokeninfo"
        assert {"Authorization", "Bearer token"} in headers
        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:ok, _result} = GoogleOAuthHelper.validate_token_scope("token", [:calendar])
    end

    test "returns error for missing scopes" do
      resp_body = Jason.encode!(%{"scope" => "https://www.googleapis.com/auth/userinfo.email"})

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:error, msg} = GoogleOAuthHelper.validate_token_scope("token", [:calendar])
      assert msg =~ "missing required scopes"
    end
  end

  describe "state management" do
    test "generates and validates state" do
      state = GoogleOAuthHelper.generate_state(456)
      assert {:ok, %{user_id: 456, integration_id: nil}} = GoogleOAuthHelper.validate_state(state)
    end

    test "fails for invalid state" do
      assert {:error, _error} = GoogleOAuthHelper.validate_state("invalid")
    end
  end
end
