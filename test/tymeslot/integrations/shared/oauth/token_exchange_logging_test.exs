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
  end
end
