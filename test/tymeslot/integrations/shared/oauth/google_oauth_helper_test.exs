defmodule Tymeslot.Integrations.Shared.OAuth.GoogleOAuthHelperTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Shared.OAuth.GoogleOAuthHelper
  alias Tymeslot.Integrations.Shared.OAuth.State
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

    # Tymeslot's own options belong in the state and the scope string; Google
    # only ever sees the parameters it defines.
    test "forwards only Google's own parameters" do
      query =
        GoogleOAuthHelper.authorization_url(123, "http://localhost/callback", [:calendar],
          return_to: "/onboarding/connect_calendar",
          scopes: [:calendar, :meet],
          hd: "example.com",
          include_granted_scopes: "true"
        )
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      refute Map.has_key?(query, "return_to")
      refute Map.has_key?(query, "scopes")
      assert query["hd"] == "example.com"
      assert query["include_granted_scopes"] == "true"

      {:ok, decoded} = State.validate(query["state"], @state_secret)
      assert decoded.return_to == "/onboarding/connect_calendar"
    end
  end

  describe "exchange_code_for_tokens/2" do
    test "exchanges the code with the client credentials" do
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
               GoogleOAuthHelper.exchange_code_for_tokens("auth-code", "http://callback")

      assert tokens.access_token == "at-123"
    end

    test "handles error from Google" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: "error_msg"}}
      end)

      assert {:error, msg} = GoogleOAuthHelper.exchange_code_for_tokens("code", "uri")
      assert msg =~ "HTTP 400"
    end

    # A proxy answering the callback's code exchange with an HTML 200 used to
    # raise `Jason.DecodeError` and crash the callback request.
    test "reports a 200 with a non-JSON body as an error" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: "<html>Sign in to the network</html>"}}
      end)

      assert {:error, "OAuth token exchange failed: HTTP 200 (see logs for details)"} =
               GoogleOAuthHelper.exchange_code_for_tokens("code", "uri")
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

    test "surfaces invalid_grant when Google returns 400 with that error" do
      resp_body =
        Jason.encode!(%{
          "error" => "invalid_grant",
          "error_description" => "Token has been expired or revoked."
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: resp_body}}
      end)

      assert {:error, msg} = GoogleOAuthHelper.refresh_access_token("revoked-rt")
      assert msg == "Token refresh failed: invalid_grant"
    end

    test "falls back to generic message when 400 body has no error field" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: "Bad Request"}}
      end)

      assert {:error, msg} = GoogleOAuthHelper.refresh_access_token("rt")
      assert msg == "Token refresh failed: HTTP 400 (see logs for details)"
    end

    test "does not surface OAuth error field for 5xx responses" do
      resp_body = Jason.encode!(%{"error" => "access_denied"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 503, body: resp_body}}
      end)

      assert {:error, msg} = GoogleOAuthHelper.refresh_access_token("rt")
      assert msg == "Token refresh failed: HTTP 503 (see logs for details)"
      refute msg =~ "access_denied"
    end
  end

  describe "exchange_code_for_tokens/2 OAuth error propagation" do
    test "surfaces invalid_grant from authorization code exchange" do
      resp_body = Jason.encode!(%{"error" => "invalid_grant"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: resp_body}}
      end)

      assert {:error, msg} = GoogleOAuthHelper.exchange_code_for_tokens("code", "uri")
      assert msg == "OAuth token exchange failed: invalid_grant"
    end
  end

  describe "state management" do
    test "signs state with the Google state secret" do
      state = GoogleOAuthHelper.generate_state(456)

      assert {:ok, %{user_id: 456, integration_id: nil}} =
               State.validate(state, @state_secret)
    end
  end

  describe "PKCE" do
    @pkce [pkce: %{nonce: "flow-nonce", code_challenge: "flow-challenge"}]

    test "the authorisation URL carries the flow's challenge, and its state the nonce" do
      query =
        GoogleOAuthHelper.authorization_url(123, "http://cb", [:calendar], @pkce)
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert query["code_challenge"] == "flow-challenge"
      assert query["code_challenge_method"] == "S256"
      assert {:ok, %{nonce: "flow-nonce"}} = State.validate(query["state"], @state_secret)
    end

    test "the code exchange presents the flow's verifier" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
        assert URI.decode_query(body)["code_verifier"] == "flow-verifier"
        {:ok, %{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      assert {:error, _reason} =
               GoogleOAuthHelper.exchange_code_for_tokens("code", "http://cb",
                 code_verifier: "flow-verifier"
               )
    end
  end
end
