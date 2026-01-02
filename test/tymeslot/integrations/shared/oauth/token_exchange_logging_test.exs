defmodule Tymeslot.Integrations.Common.OAuth.TokenExchangeLoggingTest do
  use ExUnit.Case, async: false # async: false because we are capturing global logs
  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Common.OAuth.TokenExchange

  import Mox
  setup :verify_on_exit!

  describe "logging in TokenExchange" do
    test "redacts response bodies in error logs" do
      # Mock HTTPClient to return an error response with a secret
      secret_body = "{\"access_token\": \"secret-123\", \"error\": \"invalid_request\"}"

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 400, body: secret_body}}
      end)

      log = capture_log(fn ->
        TokenExchange.refresh_access_token("http://oauth", %{refresh_token: "ref-123"})
      end)

      assert log =~ "OAuth token refresh failed"
      assert log =~ "access_token: \"[REDACTED]\""
      refute log =~ "secret-123"
    end

    test "truncates extremely long error bodies" do
      long_error = String.duplicate("error_msg_content ", 500)

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 500, body: long_error}}
      end)

      log = capture_log(fn ->
        TokenExchange.refresh_access_token("http://oauth", %{refresh_token: "ref-123"})
      end)

      assert log =~ "[TRUNCATED]"
      assert byte_size(log) < 5000 # Verify it didn't log the full 9KB+ string
    end
  end
end
