defmodule Tymeslot.Integrations.Common.OAuth.ErrorParserTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Common.OAuth.ErrorParser

  describe "build_message/3" do
    test "extracts OAuth error type from a 400 response with valid OAuth-error JSON" do
      body =
        Jason.encode!(%{"error" => "invalid_client", "error_description" => "Unknown client"})

      assert ErrorParser.build_message("Token refresh failed", 400, body) ==
               "Token refresh failed: invalid_client"
    end

    test "extracts OAuth error type from a 401 response with valid OAuth-error JSON" do
      body = Jason.encode!(%{"error" => "invalid_grant"})

      assert ErrorParser.build_message("Token refresh failed", 401, body) ==
               "Token refresh failed: invalid_grant"
    end

    test "falls back to generic message for 400 with non-OAuth JSON body" do
      body = Jason.encode!(%{"message" => "something went wrong"})

      assert ErrorParser.build_message("Token refresh failed", 400, body) ==
               "Token refresh failed: HTTP 400 (see logs for details)"
    end

    test "falls back to generic message for 400 with non-JSON binary body" do
      assert ErrorParser.build_message("Token refresh failed", 400, "Bad Request") ==
               "Token refresh failed: HTTP 400 (see logs for details)"
    end

    test "falls back to generic message for 503 even when body has OAuth-shaped JSON" do
      body = Jason.encode!(%{"error" => "access_denied"})

      assert ErrorParser.build_message("Token refresh failed", 503, body) ==
               "Token refresh failed: HTTP 503 (see logs for details)"
    end

    test "falls back to generic message for 500 with OAuth-shaped JSON" do
      body = Jason.encode!(%{"error" => "invalid_grant"})

      assert ErrorParser.build_message("Token refresh failed", 500, body) ==
               "Token refresh failed: HTTP 500 (see logs for details)"
    end

    test "falls back to generic message for non-binary body (defensive)" do
      assert ErrorParser.build_message("Token refresh failed", 400, nil) ==
               "Token refresh failed: HTTP 400 (see logs for details)"
    end

    test "uses the provided prefix in all outcomes" do
      body = Jason.encode!(%{"error" => "invalid_client"})

      assert ErrorParser.build_message("OAuth token exchange failed", 400, body) ==
               "OAuth token exchange failed: invalid_client"

      assert ErrorParser.build_message("OAuth token exchange failed", 502, body) ==
               "OAuth token exchange failed: HTTP 502 (see logs for details)"
    end
  end
end
