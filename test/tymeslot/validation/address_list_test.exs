defmodule Tymeslot.Validation.AddressListTest do
  use ExUnit.Case, async: true

  @moduletag :meetings

  alias Tymeslot.Validation.AddressList

  describe "split/1" do
    test "splits on commas, semicolons and line breaks, keeping a quoted name whole" do
      assert AddressList.split(~s(a@example.com; "Hopper, Grace" <grace@example.com>\nb@x.com)) ==
               ["a@example.com", ~s("Hopper, Grace" <grace@example.com>), "b@x.com"]
    end

    test "returns nothing for nothing" do
      assert AddressList.split(" , \n") == []
      assert AddressList.split(nil) == []
    end
  end

  describe "parse_entry/1" do
    test "reads a name and an address, and a bare address" do
      assert AddressList.parse_entry("Grace Hopper <Grace@Example.com>") ==
               %{email: "grace@example.com", name: "Grace Hopper"}

      assert AddressList.parse_entry(~s("Hopper, Grace" <grace@example.com>)) ==
               %{email: "grace@example.com", name: "Hopper, Grace"}

      assert AddressList.parse_entry(" Ada@Example.com ") == %{
               email: "ada@example.com",
               name: nil
             }

      assert AddressList.parse_entry("<ada@example.com>") == %{
               email: "ada@example.com",
               name: nil
             }
    end
  end

  test "checks addresses and names" do
    assert AddressList.valid_address?(%{email: "ada@example.com", name: nil})
    refute AddressList.valid_address?(%{email: "not an address", name: nil})
    assert AddressList.valid_name?(%{email: "", name: "Grace Hopper"})
    assert AddressList.valid_name?(%{email: "", name: nil})
    refute AddressList.valid_name?(%{email: "", name: "<script>"})
  end

  test "writes an entry back as typed" do
    assert AddressList.format(%{email: "g@example.com", name: "Grace"}) == "Grace <g@example.com>"
    assert AddressList.format(%{email: "g@example.com", name: nil}) == "g@example.com"
  end
end
