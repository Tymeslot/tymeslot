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

  describe "generate_email_verification_token/1" do
    test "returns a {token, expiry, purpose} tuple" do
      {token, expiry, purpose} = Token.generate_email_verification_token(1)

      assert %DateTime{} = expiry
      assert purpose == "email_verification"
      assert String.length(token) == 43
    end

    test "expiry is approximately 24 hours from now" do
      {_token, expiry, _purpose} = Token.generate_email_verification_token(1)

      diff = DateTime.diff(expiry, DateTime.utc_now(), :second)
      assert_in_delta diff, 24 * 3600, 5
    end
  end

  describe "verify_token/2" do
    test "returns {:ok, token} when not expired" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, "test_token"} = Token.verify_token("test_token", future)
    end

    test "returns {:error, :token_expired} when expired" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert {:error, :token_expired} = Token.verify_token("test_token", past)
    end

    test "returns {:error, :token_expired} when expiry is exactly now" do
      now = DateTime.utc_now()
      # :eq falls through to the _expired clause
      assert {:error, :token_expired} = Token.verify_token("test_token", now)
    end
  end

  describe "verify_token_secure/3" do
    test "returns {:ok, token} when token matches and not expired" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, "correct_token"} =
               Token.verify_token_secure("correct_token", "correct_token", future)
    end

    test "returns {:error, :token_invalid} when token does not match" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:error, :token_invalid} = Token.verify_token_secure("wrong", "correct", future)
    end

    test "returns {:error, :token_invalid} when expired even if token matches" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert {:error, :token_invalid} = Token.verify_token_secure("token", "token", past)
    end

    test "returns {:error, :token_invalid} when both wrong and expired" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert {:error, :token_invalid} = Token.verify_token_secure("wrong", "correct", past)
    end
  end

  describe "secure_compare_tokens/2" do
    test "returns true for identical tokens" do
      assert Token.secure_compare_tokens("abc123", "abc123")
    end

    test "returns false for different tokens" do
      refute Token.secure_compare_tokens("abc123", "xyz789")
    end

    test "returns false for non-binary arguments" do
      refute Token.secure_compare_tokens(nil, "token")
      refute Token.secure_compare_tokens("token", nil)
      refute Token.secure_compare_tokens(123, 456)
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

    test "password reset token has 2-hour expiry" do
      {_token, expiry} = Token.generate_password_reset_token()

      diff = DateTime.diff(expiry, DateTime.utc_now(), :second)
      assert_in_delta diff, 2 * 3600, 5
    end
  end
end
