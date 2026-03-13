defmodule Tymeslot.Embed.TokenTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :security

  alias Tymeslot.Embed.Token

  describe "sign/1" do
    test "returns a binary token" do
      token = Token.sign("sarah")
      assert is_binary(token)
    end

    test "different usernames produce different tokens" do
      assert Token.sign("sarah") != Token.sign("bob")
    end
  end

  describe "verify/1" do
    test "verifies a valid token and returns the username" do
      token = Token.sign("sarah")
      assert {:ok, "sarah"} = Token.verify(token)
    end

    test "rejects a tampered token" do
      assert {:error, :invalid} = Token.verify("tampered.token.value")
    end

    test "rejects an expired token" do
      token = Token.sign("sarah")
      assert {:error, :expired} = Token.verify(token, max_age: 0)
    end

    test "rejects a token with non-string payload" do
      # Sign a non-string value directly to test the guard
      token = Phoenix.Token.sign(TymeslotWeb.Endpoint, "embed_session", 12345)
      assert {:error, :invalid} = Token.verify(token)
    end
  end
end
