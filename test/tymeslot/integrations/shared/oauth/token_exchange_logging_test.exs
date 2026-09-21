defmodule Tymeslot.Integrations.Common.OAuth.TokenExchangeLoggingTest do
  # async: false because we are capturing global logs
  use ExUnit.Case, async: false

  @moduletag :integrations

  alias Tymeslot.Integrations.Common.OAuth.TokenExchange
  alias Tymeslot.Test.LogCapture

  import Mox
  setup :verify_on_exit!

  describe "logging in TokenExchange" do
    test "redacts response bodies in error logs" do
      # Mock HTTPClient to return an error response with a secret
      secret_body = "{\"access_token\": \"secret-123\", \"error\": \"invalid_request\"}"

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: secret_body}}
      end)

      LogCapture.attach()

      TokenExchange.refresh_access_token("http://oauth", %{refresh_token: "ref-123"})

      # The body goes to metadata, which the console formatter drops, so this
      # must be asserted against the captured record rather than `capture_log`.
      refute LogCapture.dump(LogCapture.await_log("OAuth token refresh failed")) =~ "secret-123"
    end

    test "truncates extremely long error bodies" do
      long_error = String.duplicate("error_msg_content ", 500)

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 500, body: long_error}}
      end)

      LogCapture.attach()

      TokenExchange.refresh_access_token("http://oauth", %{refresh_token: "ref-123"})

      event = LogCapture.await_log("OAuth token refresh failed")

      # Verify the full body isn't logged verbatim
      assert byte_size(LogCapture.user_metadata(event)[:body]) < byte_size(long_error)
      assert byte_size(LogCapture.dump(event)) < 5000
    end

    # Without this the line says only which status came back, and attributing
    # one of a batch of simultaneous refresh failures means joining against a
    # neighbouring line from another module on timestamp.
    test "names the integration behind a refresh failure" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      LogCapture.attach()

      TokenExchange.refresh_access_token("http://oauth", %{refresh_token: "ref-123"},
        log_context: [integration_id: 42, user_id: 7, provider: :google]
      )

      meta = LogCapture.user_metadata(LogCapture.await_log("OAuth token refresh failed"))

      assert meta[:integration_id] == 42
      assert meta[:user_id] == 7
      assert meta[:provider] == :google
      assert meta[:status] == 400
    end

    # The correlation id is process metadata that `ObanLogger` and the request
    # plug set, and the JSON formatter emits all of it, so threading it through
    # here would duplicate it where it works and change nothing where it does
    # not. It is off the allowed list, and a caller passing one is ignored.
    test "does not take a caller-supplied correlation id" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      LogCapture.attach()

      TokenExchange.refresh_access_token("http://oauth", %{refresh_token: "ref-123"},
        log_context: [integration_id: 42, correlation_id: "abc-1"]
      )

      meta = LogCapture.user_metadata(LogCapture.await_log("OAuth token refresh failed"))

      assert meta[:integration_id] == 42
      refute Map.has_key?(meta, :correlation_id)
    end

    test "names the integration behind a network error during refresh" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      LogCapture.attach()

      TokenExchange.refresh_access_token("http://oauth", %{refresh_token: "ref-123"},
        log_context: [integration_id: 42, provider: :zoom]
      )

      meta = LogCapture.user_metadata(LogCapture.await_log("Network error during token refresh"))

      assert meta[:integration_id] == 42
      assert meta[:provider] == :zoom
    end

    # The allowed-key list is what stops a caller widening the line, and what
    # stops an integration struct — which carries the encrypted credentials —
    # reaching the logs through a key nobody vetted.
    test "drops log context keys outside the allowed set" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      LogCapture.attach()

      TokenExchange.refresh_access_token("http://oauth", %{refresh_token: "ref-123"},
        log_context: [
          integration_id: 42,
          access_token: "secret-123",
          refresh_token: "secret-456",
          user_id: nil
        ]
      )

      event = LogCapture.await_log("OAuth token refresh failed")
      meta = LogCapture.user_metadata(event)

      assert meta[:integration_id] == 42
      refute Map.has_key?(meta, :access_token)
      refute Map.has_key?(meta, :refresh_token)
      refute Map.has_key?(meta, :user_id)
      refute LogCapture.dump(event) =~ "secret-123"
      refute LogCapture.dump(event) =~ "secret-456"
    end
  end
end
