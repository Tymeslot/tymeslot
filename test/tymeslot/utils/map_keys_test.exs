defmodule Tymeslot.Utils.MapKeysTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Utils.MapKeys

  describe "get/2" do
    test "reads the atom key when present" do
      assert MapKeys.get(%{email: "a@example.com"}, :email) == "a@example.com"
    end

    test "falls back to the string key when the atom key is absent" do
      assert MapKeys.get(%{"email" => "a@example.com"}, :email) == "a@example.com"
    end

    test "returns nil when neither key is present" do
      assert MapKeys.get(%{}, :email) == nil
    end

    test "returns nil when the atom key is present but nil" do
      assert MapKeys.get(%{email: nil}, :email) == nil
    end
  end

  describe "get_binary/2" do
    test "returns the value when it is a binary under the atom key" do
      assert MapKeys.get_binary(%{uid: "abc"}, :uid) == "abc"
    end

    test "returns the value when it is a binary under the string key" do
      assert MapKeys.get_binary(%{"uid" => "abc"}, :uid) == "abc"
    end

    test "returns nil when the value is present but not a binary" do
      assert MapKeys.get_binary(%{uid: 123}, :uid) == nil
    end

    test "returns nil when the key is absent" do
      assert MapKeys.get_binary(%{}, :uid) == nil
    end

    test "returns nil when given a non-map term" do
      assert MapKeys.get_binary("abc", :uid) == nil
      assert MapKeys.get_binary(nil, :uid) == nil
    end
  end
end
