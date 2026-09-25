defmodule Tymeslot.Security.SharedSecretTest do
  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :webhooks
  @moduletag :unit

  alias Tymeslot.Security.SharedSecret

  describe "matches?/2" do
    test "matches equal non-empty secrets" do
      assert SharedSecret.matches?("s3cret", "s3cret")
    end

    test "rejects a different secret" do
      refute SharedSecret.matches?("s3cret", "other")
    end

    test "rejects two empty secrets" do
      refute SharedSecret.matches?("", "")
    end

    test "rejects when either side is missing" do
      refute SharedSecret.matches?(nil, "s3cret")
      refute SharedSecret.matches?("s3cret", nil)
      refute SharedSecret.matches?(nil, nil)
    end

    test "rejects a non-string value" do
      refute SharedSecret.matches?(123, "123")
    end
  end
end
