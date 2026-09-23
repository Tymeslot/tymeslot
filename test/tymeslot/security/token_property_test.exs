defmodule Tymeslot.Security.TokenPropertyTest do
  @moduledoc """
  Property-based tests for token generation and verification in `Tymeslot.Security.Token`.

  Since token generation functions take no meaningful input, we use the
  `constant(nil)` generator pattern to drive repeated invocations.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :security
  use ExUnitProperties

  alias Tymeslot.Security.Token

  describe "session token properties" do
    property "session tokens are valid base64url without padding" do
      check all(_run <- constant(nil), max_runs: 50) do
        token = Token.generate_session_token()
        assert token =~ ~r/\A[A-Za-z0-9_-]+\z/, "Token contains invalid base64url characters"
        refute String.contains?(token, "="), "Token contains padding character"
        refute String.contains?(token, "+"), "Token contains + (standard base64, not url-safe)"
        refute String.contains?(token, "/"), "Token contains / (standard base64, not url-safe)"
      end
    end

    property "session tokens have consistent length (43 chars for 32 random bytes)" do
      check all(_run <- constant(nil), max_runs: 50) do
        token = Token.generate_session_token()
        assert String.length(token) == 43
      end
    end
  end

  describe "generate_session_token/1 (with user_id)" do
    test "returns a {token, expiry} tuple" do
      {token, expiry} = Token.generate_session_token(1)

      assert %DateTime{} = expiry
      assert String.length(token) == 43
    end

    test "expiry is approximately 24 hours from now" do
      {_token, expiry} = Token.generate_session_token(1)

      diff = DateTime.diff(expiry, DateTime.utc_now(), :second)
      # Allow 5 seconds of clock drift
      assert_in_delta diff, 24 * 3600, 5
    end
  end

  describe "generic token properties" do
    property "generic tokens are valid base64url without padding" do
      check all(_run <- constant(nil), max_runs: 50) do
        token = Token.generate_token()
        assert token =~ ~r/\A[A-Za-z0-9_-]+\z/, "Token contains invalid base64url characters"
        refute String.contains?(token, "="), "Token contains padding character"
        refute String.contains?(token, "+"), "Token contains + (standard base64, not url-safe)"
        refute String.contains?(token, "/"), "Token contains / (standard base64, not url-safe)"
      end
    end
  end
end
