defmodule Tymeslot.Embed.TokenTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :security

  alias Tymeslot.Embed.Token

  describe "sign/2" do
    test "returns a binary token" do
      token = Token.sign("sarah")
      assert is_binary(token)
    end

    test "different usernames produce different tokens" do
      assert Token.sign("sarah") != Token.sign("bob")
    end

    test "parent_origin defaults to nil" do
      assert {:ok, {"sarah", nil}} = Token.verify(Token.sign("sarah"))
    end

    test "includes parent_origin in payload" do
      token = Token.sign("sarah", "https://example.com")
      assert {:ok, {"sarah", "https://example.com"}} = Token.verify(token)
    end
  end

  describe "verify/2" do
    test "verifies a valid token and returns username with parent_origin" do
      token = Token.sign("sarah", "https://example.com")
      assert {:ok, {"sarah", "https://example.com"}} = Token.verify(token)
    end

    test "verifies a token with nil parent_origin" do
      token = Token.sign("sarah")
      assert {:ok, {"sarah", nil}} = Token.verify(token)
    end

    test "rejects a tampered token" do
      assert {:error, :invalid} = Token.verify("tampered.token.value")
    end

    test "rejects an expired token" do
      token = Token.sign("sarah", "https://example.com")
      assert {:error, :expired} = Token.verify(token, max_age: 0)
    end

    test "rejects a token with non-tuple payload" do
      # Sign a non-tuple value directly to test the guard
      token = Phoenix.Token.sign(TymeslotWeb.Endpoint, "embed_session", 12_345)
      assert {:error, :invalid} = Token.verify(token)
    end

    test "rejects a token with old string-only payload" do
      # Old format (pre parent_origin) — should be rejected
      token = Phoenix.Token.sign(TymeslotWeb.Endpoint, "embed_session", "sarah")
      assert {:error, :invalid} = Token.verify(token)
    end
  end

  describe "Task 116: forge/expiry/cross-user boundary coverage" do
    # Rotated or foreign secret_key_base is simulated by signing with a
    # different salt — Phoenix.Token derives the verifier secret from
    # secret_key_base <> salt, so a mismatch here is equivalent to a
    # mismatch in secret_key_base from the verifier's perspective.
    test "token signed with a foreign salt (rotated key) is rejected as :invalid" do
      foreign = Phoenix.Token.sign(TymeslotWeb.Endpoint, "different-salt", {"sarah", nil})
      assert {:error, :invalid} = Token.verify(foreign)
    end

    test "token with signed_at older than max_age is rejected as :expired" do
      past_seconds = System.system_time(:second) - 21_700

      stale =
        Phoenix.Token.sign(
          TymeslotWeb.Endpoint,
          "embed_session",
          {"sarah", nil},
          signed_at: past_seconds
        )

      assert {:error, :expired} = Token.verify(stale)
    end

    test "token signed just within max_age still verifies" do
      past_seconds = System.system_time(:second) - 30

      fresh =
        Phoenix.Token.sign(
          TymeslotWeb.Endpoint,
          "embed_session",
          {"sarah", nil},
          signed_at: past_seconds
        )

      assert {:ok, {"sarah", nil}} = Token.verify(fresh, max_age: 60)
    end

    test "user A's token decodes to user A's username only — never user B's" do
      # The embed controller uses the decoded username to look up the profile.
      # If verify/1 ever returned the wrong username for a valid token, a
      # viewer could see another profile's availability. Pin the identity
      # guarantee explicitly.
      token_a = Token.sign("user-a")
      token_b = Token.sign("user-b")

      assert {:ok, {"user-a", nil}} = Token.verify(token_a)
      assert {:ok, {"user-b", nil}} = Token.verify(token_b)
      refute match?({:ok, {"user-b", _}}, Token.verify(token_a))
    end
  end
end
