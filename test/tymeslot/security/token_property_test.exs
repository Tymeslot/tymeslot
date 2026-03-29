defmodule Tymeslot.Security.TokenPropertyTest do
  @moduledoc """
  Property-based tests for token generation in `Tymeslot.Security.Token`.

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

    property "successive session tokens are unique" do
      check all(_run <- constant(nil), max_runs: 50) do
        token_a = Token.generate_session_token()
        token_b = Token.generate_session_token()
        assert token_a != token_b
      end
    end
  end

  describe "password reset token properties" do
    property "password reset tokens are valid base64url without padding" do
      check all(_run <- constant(nil), max_runs: 50) do
        {token, _expiry} = Token.generate_password_reset_token()
        assert token =~ ~r/\A[A-Za-z0-9_-]+\z/, "Token contains invalid base64url characters"
        refute String.contains?(token, "="), "Token contains padding character"
        refute String.contains?(token, "+"), "Token contains + (standard base64, not url-safe)"
        refute String.contains?(token, "/"), "Token contains / (standard base64, not url-safe)"
      end
    end
  end
end
