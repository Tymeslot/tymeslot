defmodule Tymeslot.Integrations.Common.OAuth.TokenExchangeTest do
  use ExUnit.Case, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Common.OAuth.TokenExchange

  import Mox
  setup :verify_on_exit!

  @token_url "https://oauth.com/token"
  @client_id "client-id"
  @client_secret "client-secret"
  @redirect_uri "https://app.com/callback"
  @code "auth-code"
  @scope "calendar.read"

  describe "exchange_code_for_tokens/6" do
    test "returns tokens on success" do
      resp_body =
        Jason.encode!(%{
          "access_token" => "at-123",
          "refresh_token" => "rt-123",
          "expires_in" => 3600,
          "scope" => @scope
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, @token_url, body, _headers, _opts ->
        # Verify body contains expected params
        decoded_body = URI.decode_query(body)
        assert decoded_body["code"] == @code
        assert decoded_body["grant_type"] == "authorization_code"

        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:ok, tokens} =
               TokenExchange.exchange_code_for_tokens(
                 @code,
                 @redirect_uri,
                 @token_url,
                 @client_id,
                 @client_secret,
                 @scope
               )

      assert tokens.access_token == "at-123"
      assert tokens.refresh_token == "rt-123"
      assert tokens.scope == @scope
      assert %DateTime{} = tokens.expires_at
    end

    test "handles HTTP error" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: "{\"error\": \"invalid_grant\"}"}}
      end)

      assert {:error, message} =
               TokenExchange.exchange_code_for_tokens(
                 @code,
                 @redirect_uri,
                 @token_url,
                 @client_id,
                 @client_secret,
                 @scope
               )

      assert message =~ "OAuth token exchange failed: HTTP 400"
    end

    test "handles network error" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, message} =
               TokenExchange.exchange_code_for_tokens(
                 @code,
                 @redirect_uri,
                 @token_url,
                 @client_id,
                 @client_secret,
                 @scope
               )

      assert message =~ "Network error"
    end
  end

  describe "refresh_access_token/3" do
    test "refreshes token successfully" do
      resp_body =
        Jason.encode!(%{
          "access_token" => "new-at",
          "expires_in" => 3600
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, @token_url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:ok, tokens} =
               TokenExchange.refresh_access_token(
                 @token_url,
                 %{refresh_token: "old-rt"},
                 fallback_refresh_token: "old-rt"
               )

      assert tokens.access_token == "new-at"
      assert tokens.refresh_token == "old-rt"
    end

    test "handles http error in refresh" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: "unauthorized"}}
      end)

      assert {:error, {:http_error, 401, _error_body}} =
               TokenExchange.refresh_access_token(@token_url, %{})
    end

    test "preserves raw response body on 400 so callers can extract the OAuth error code" do
      # Regression guard: a previous implementation returned a redacted placeholder
      # string instead of the raw body, which broke ErrorParser.build_message/3 and
      # prevented `invalid_grant` from being detected as a permanent auth failure.
      raw_body = Jason.encode!(%{"error" => "invalid_grant"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: raw_body}}
      end)

      assert {:error, {:http_error, 400, error_body}} =
               TokenExchange.refresh_access_token(@token_url, %{})

      assert error_body =~ "invalid_grant"
    end
  end
end
