defmodule Tymeslot.Integrations.Providers.FamiliesTest do
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Providers.Families

  describe "all/0" do
    test "is the vocabulary every domain and the picker share" do
      assert Families.all() == [:oauth, :caldav, :ews, :subscription, :other]
    end

    test "puts the catch-all last so nothing sorts above a named group" do
      assert List.last(Families.all()) == :other
    end
  end

  describe "build_index/2" do
    test "keys every provider by both its atom and its string form" do
      index = Families.build_index(%{oauth: [:google], caldav: [:baikal]}, [:google, :baikal])

      assert Families.of(index, :google) == :oauth
      assert Families.of(index, "google") == :oauth
      assert Families.of(index, :baikal) == :caldav
      assert Families.of(index, "baikal") == :caldav
    end

    test "rejects a family outside the vocabulary" do
      assert_raise ArgumentError, ~r/unknown provider families \[:carrier_pigeon\]/, fn ->
        Families.build_index(%{carrier_pigeon: [:google]}, [:google])
      end
    end

    test "rejects a provider the domain declares but the table does not file" do
      assert_raise ArgumentError, ~r/\[:outlook\] missing from the family table/, fn ->
        Families.build_index(%{oauth: [:google]}, [:google, :outlook])
      end
    end

    test "rejects a provider filed under two families" do
      assert_raise ArgumentError, ~r/\[:google\] filed under more than one family/, fn ->
        Families.build_index(%{oauth: [:google], other: [:google]}, [:google])
      end
    end

    test "rejects a provider the table files but the domain does not have" do
      assert_raise ArgumentError, ~r/\[:zoom\] in the family table but not a provider/, fn ->
        Families.build_index(%{oauth: [:google, :zoom]}, [:google])
      end
    end

    test "accepts a family the domain has no members for" do
      index = Families.build_index(%{oauth: [:google]}, [:google])

      assert Families.of(index, :google) == :oauth
      assert Families.of(index, :anything_else) == :other
    end
  end

  describe "of/2" do
    test "answers :other for a provider the index has never heard of" do
      index = Families.build_index(%{oauth: [:google]}, [:google])

      assert Families.of(index, :nope) == :other
      assert Families.of(index, "nope") == :other
      assert Families.of(index, nil) == :other
      assert Families.of(index, 42) == :other
    end
  end

  describe "members/2 and member_strings/2" do
    test "return the family's providers in declaration order" do
      table = %{caldav: [:caldav, :radicale, :baikal]}

      assert Families.members(table, :caldav) == [:caldav, :radicale, :baikal]
      assert Families.member_strings(table, :caldav) == ["caldav", "radicale", "baikal"]
    end

    test "return an empty list for a family the domain does not use" do
      assert Families.members(%{oauth: [:google]}, :subscription) == []
      assert Families.member_strings(%{oauth: [:google]}, :subscription) == []
    end
  end
end
