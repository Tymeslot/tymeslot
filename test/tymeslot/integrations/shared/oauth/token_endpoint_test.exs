defmodule Tymeslot.Integrations.Shared.OAuth.TokenEndpointTest do
  # async: false: LogCapture attaches a global `:logger` handler.
  use ExUnit.Case, async: false

  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Shared.OAuth.TokenEndpoint
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  @token_url "https://oauth.example/token"

  defp respond(status, body) do
    expect(Tymeslot.HTTPClientMock, :request, fn :post, @token_url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: status, body: body}}
    end)
  end

  describe "exchange_code/3" do
    test "posts the form and returns the normalised tokens" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, @token_url, body, headers, _opts ->
        assert URI.decode_query(body) == %{
                 "code" => "auth-code",
                 "grant_type" => "authorization_code"
               }

        assert headers == [{"Content-Type", "application/x-www-form-urlencoded"}]

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "access_token" => "at-123",
               "refresh_token" => "rt-123",
               "id_token" => "id-123",
               "expires_in" => 1800,
               "scope" => "calendar"
             })
         }}
      end)

      before = DateTime.utc_now()

      assert {:ok, tokens} =
               TokenEndpoint.exchange_code(@token_url, %{
                 code: "auth-code",
                 grant_type: "authorization_code"
               })

      assert %{access_token: "at-123", refresh_token: "rt-123", id_token: "id-123"} = tokens
      assert tokens.scope == "calendar"
      assert DateTime.diff(tokens.expires_at, before) in 1799..1801
    end

    test "sends caller-supplied headers instead of the default" do
      headers = [{"Authorization", "Basic abc"}]

      expect(Tymeslot.HTTPClientMock, :request, fn :post, @token_url, _body, ^headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ~s({"access_token":"at"})}}
      end)

      assert {:ok, %{access_token: "at"}} =
               TokenEndpoint.exchange_code(@token_url, %{}, headers: headers)
    end

    test "redacts the response body of a failed exchange" do
      respond(400, ~s({"access_token":"leaked-123","error":"invalid_request"}))
      LogCapture.attach()

      assert {:error, {:http_error, 400, _body}} =
               TokenEndpoint.exchange_code(@token_url, %{code: "c"},
                 log_context: [provider: :google]
               )

      event = LogCapture.await_log("OAuth token exchange failed")

      assert LogCapture.user_metadata(event)[:provider] == :google
      refute LogCapture.dump(event) =~ "leaked-123"
    end
  end

  describe "refresh/3" do
    test "keeps the fallback refresh token when the provider does not rotate it" do
      respond(200, ~s({"access_token":"new-at","expires_in":3600}))

      assert {:ok, tokens} =
               TokenEndpoint.refresh(@token_url, %{refresh_token: "old-rt"},
                 fallback_refresh_token: "old-rt",
                 fallback_scope: "calendar"
               )

      assert tokens.access_token == "new-at"
      assert tokens.refresh_token == "old-rt"
      assert tokens.scope == "calendar"
    end

    # Persisting "" would replace a working refresh token with nothing, and the
    # next refresh would fail as a revoked grant.
    test "keeps the fallback when the provider answers a blank refresh token" do
      respond(200, ~s({"access_token":"new-at","refresh_token":""}))

      assert {:ok, %{refresh_token: "old-rt"}} =
               TokenEndpoint.refresh(@token_url, %{}, fallback_refresh_token: "old-rt")
    end

    test "reports a 200 without an access token as an error" do
      for body <- [~s({"refresh_token":"rt"}), ~s({"access_token":""})] do
        respond(200, body)
        LogCapture.attach()

        assert {:error, {:http_error, 200, "Token response without an access token"}} =
                 TokenEndpoint.refresh(@token_url, %{}, log_context: [integration_id: 42])

        meta =
          LogCapture.user_metadata(
            LogCapture.await_log("OAuth token refresh returned no access token")
          )

        assert meta[:integration_id] == 42
      end
    end

    test "takes a rotated refresh token over the fallback" do
      respond(200, ~s({"access_token":"new-at","refresh_token":"new-rt"}))

      assert {:ok, %{refresh_token: "new-rt"}} =
               TokenEndpoint.refresh(@token_url, %{}, fallback_refresh_token: "old-rt")
    end

    test "preserves the raw body of a refusal so callers can read the OAuth error code" do
      raw_body = ~s({"error":"invalid_grant"})
      respond(400, raw_body)

      assert {:error, {:http_error, 400, ^raw_body}} = TokenEndpoint.refresh(@token_url, %{})
    end

    test "reports a network failure" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      LogCapture.attach()

      assert {:error, {:network_error, :timeout}} =
               TokenEndpoint.refresh(@token_url, %{}, log_context: [integration_id: 42])

      meta = LogCapture.user_metadata(LogCapture.await_log("Network error during token refresh"))
      assert meta[:integration_id] == 42
    end
  end

  describe "refresh_grant/4" do
    defmodule Provider do
      @moduledoc false
      @behaviour Tymeslot.Integrations.Shared.OAuthConfig

      @impl Tymeslot.Integrations.Shared.OAuthConfig
      def fetch_client_id, do: {:ok, "client-id"}
      @impl Tymeslot.Integrations.Shared.OAuthConfig
      def fetch_client_secret, do: {:ok, "client-secret"}
      @impl Tymeslot.Integrations.Shared.OAuthConfig
      def token_url, do: "https://oauth.example/token"
    end

    defmodule Unconfigured do
      @moduledoc false
      @behaviour Tymeslot.Integrations.Shared.OAuthConfig

      @impl Tymeslot.Integrations.Shared.OAuthConfig
      def fetch_client_id, do: {:error, "Example Client ID not configured"}
      @impl Tymeslot.Integrations.Shared.OAuthConfig
      def fetch_client_secret, do: {:ok, "client-secret"}
      @impl Tymeslot.Integrations.Shared.OAuthConfig
      def token_url, do: "https://oauth.example/token"
    end

    test "sends the refresh-token grant with the client credentials and the scope" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, @token_url, body, _headers, _opts ->
        assert URI.decode_query(body) == %{
                 "grant_type" => "refresh_token",
                 "refresh_token" => "rt",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret",
                 "scope" => "calendar"
               }

        {:ok, %Req.Response{status: 200, body: ~s({"access_token":"at"})}}
      end)

      assert {:ok, %{access_token: "at", refresh_token: "rt", scope: "calendar"}} =
               TokenEndpoint.refresh_grant(Provider, "rt", "calendar")
    end

    test "leaves the scope out when none is given" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, @token_url, body, _headers, _opts ->
        refute Map.has_key?(URI.decode_query(body), "scope")
        {:ok, %Req.Response{status: 200, body: ~s({"access_token":"at"})}}
      end)

      assert {:ok, %{access_token: "at"}} = TokenEndpoint.refresh_grant(Provider, "rt", nil)
    end

    test "reports missing client credentials without calling the provider" do
      assert {:error, {:not_configured, "Example Client ID not configured"} = error} =
               TokenEndpoint.refresh_grant(Unconfigured, "rt", nil)

      assert TokenEndpoint.error_message(:refresh, error) == "Example Client ID not configured"
    end
  end

  # A proxy or captive portal answering 200 with an HTML page used to raise
  # `Jason.DecodeError` out of the Google code exchange and the Outlook
  # calendar refresh, inside the refresh lock.
  describe "a 200 whose body is not JSON" do
    test "is an error for an exchange, not a raise" do
      respond(200, "<html>Sign in to the network</html>")
      LogCapture.attach()

      assert {:error, {:http_error, 200, "Invalid JSON response from token endpoint"}} =
               TokenEndpoint.exchange_code(@token_url, %{}, log_context: [provider: :google])

      event = LogCapture.await_log("OAuth token exchange returned invalid JSON")
      assert LogCapture.user_metadata(event)[:provider] == :google
    end

    test "is an error for a refresh, not a raise" do
      respond(200, "<html>Sign in to the network</html>")

      assert {:error, {:http_error, 200, _reason}} = TokenEndpoint.refresh(@token_url, %{})
    end

    test "includes JSON that is not an object" do
      respond(200, ~s(["access_token"]))

      assert {:error, {:http_error, 200, _reason}} = TokenEndpoint.refresh(@token_url, %{})
    end
  end

  describe "failure log lines" do
    test "redact the response body" do
      respond(400, ~s({"access_token": "secret-123", "error": "invalid_request"}))
      LogCapture.attach()

      TokenEndpoint.refresh(@token_url, %{refresh_token: "ref-123"})

      # The body goes to metadata, which the console formatter drops, so this
      # must be asserted against the captured record rather than `capture_log`.
      refute LogCapture.dump(LogCapture.await_log("OAuth token refresh failed")) =~ "secret-123"
    end

    test "truncate extremely long bodies" do
      long_error = String.duplicate("error_msg_content ", 500)
      respond(500, long_error)
      LogCapture.attach()

      TokenEndpoint.refresh(@token_url, %{refresh_token: "ref-123"})

      event = LogCapture.await_log("OAuth token refresh failed")

      assert byte_size(LogCapture.user_metadata(event)[:body]) < byte_size(long_error)
      assert byte_size(LogCapture.dump(event)) < 5000
    end

    # Without this the line says only which status came back, and attributing
    # one of a batch of simultaneous refresh failures means joining against a
    # neighbouring line from another module on timestamp.
    test "name the integration behind the failure" do
      respond(400, ~s({"error":"invalid_grant"}))
      LogCapture.attach()

      TokenEndpoint.refresh(@token_url, %{},
        log_context: [integration_id: 42, user_id: 7, provider: :google]
      )

      meta = LogCapture.user_metadata(LogCapture.await_log("OAuth token refresh failed"))

      assert meta[:integration_id] == 42
      assert meta[:user_id] == 7
      assert meta[:provider] == :google
      assert meta[:status] == 400
    end

    # The allowed-key list is what stops a caller widening the line, and what
    # stops a credential reaching the logs through a key nobody vetted. The
    # correlation id is off the list too: it is process metadata the JSON
    # formatter already emits.
    test "drop log context keys outside the allowed set, and nils" do
      respond(400, ~s({"error":"invalid_grant"}))
      LogCapture.attach()

      TokenEndpoint.refresh(@token_url, %{},
        log_context: [
          integration_id: 42,
          access_token: "secret-123",
          refresh_token: "secret-456",
          correlation_id: "abc-1",
          user_id: nil
        ]
      )

      event = LogCapture.await_log("OAuth token refresh failed")
      meta = LogCapture.user_metadata(event)

      assert meta[:integration_id] == 42
      refute Map.has_key?(meta, :access_token)
      refute Map.has_key?(meta, :refresh_token)
      refute Map.has_key?(meta, :correlation_id)
      refute Map.has_key?(meta, :user_id)
      refute LogCapture.dump(event) =~ "secret-123"
      refute LogCapture.dump(event) =~ "secret-456"
    end
  end

  describe "normalise_tokens/2" do
    test "assumes an hour when expires_in is missing or not an integer" do
      before = DateTime.utc_now()

      for response <- [%{}, %{"expires_in" => "3600"}] do
        tokens = TokenEndpoint.normalise_tokens(response)
        assert DateTime.diff(tokens.expires_at, before) in 3599..3601
      end
    end

    test "reports no refresh token or scope when there is neither a value nor a fallback" do
      assert %{refresh_token: nil, scope: nil} = TokenEndpoint.normalise_tokens(%{})
    end
  end

  describe "error_message/2" do
    test "carries the OAuth error code of a refusal" do
      assert TokenEndpoint.error_message(
               :refresh,
               {:http_error, 400, ~s({"error":"invalid_grant"})}
             ) ==
               "Token refresh failed: invalid_grant"

      assert TokenEndpoint.error_message(
               :exchange,
               {:http_error, 401, ~s({"error":"invalid_client"})}
             ) ==
               "OAuth token exchange failed: invalid_client"
    end

    test "names a network failure and the operation" do
      assert TokenEndpoint.error_message(:exchange, {:network_error, :timeout}) ==
               "Network error during token exchange: :timeout"
    end
  end
end
