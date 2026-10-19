defmodule Tymeslot.Security.TokenPropertyTest do
  @moduledoc """
  Property-based tests for `Tymeslot.Security.Token.generate/1`, the one place
  the app mints random tokens.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :security
  use ExUnitProperties

  alias Tymeslot.Security.Token

  property "tokens are base64url without padding, and as long as their byte count implies" do
    check all(bytes <- integer(1..64), max_runs: 100) do
      token = Token.generate(bytes)

      assert token =~ ~r/\A[A-Za-z0-9_-]+\z/
      assert String.length(token) == ceil(bytes * 4 / 3)
      assert byte_size(Base.url_decode64!(token, padding: false)) == bytes
    end
  end

  test "the default is 32 bytes, 43 characters" do
    assert String.length(Token.generate()) == 43
  end

  test "tokens do not repeat" do
    tokens = for _i <- 1..200, do: Token.generate(24)
    assert Enum.uniq(tokens) == tokens
  end
end
