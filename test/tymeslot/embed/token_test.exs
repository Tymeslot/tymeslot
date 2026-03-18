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
end
