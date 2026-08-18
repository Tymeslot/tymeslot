defmodule Tymeslot.Utils.UnguessableTokenTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Utils.UnguessableToken

  test "generates URL-safe tokens of expected entropy" do
    token = UnguessableToken.generate()

    assert String.length(token) == 32
    assert token =~ ~r/^[A-Za-z0-9_-]+$/
  end

  test "tokens are unique" do
    tokens = for _i <- 1..100, do: UnguessableToken.generate()
    assert Enum.uniq(tokens) == tokens
  end
end
