defmodule Tymeslot.Integrations.Providers.DirectoryTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Providers.Descriptor
  alias Tymeslot.Integrations.Providers.Directory

  describe "list/1" do
    test "lists calendar providers" do
      list = Directory.list(:calendar)
      assert is_list(list)
      assert list != []
      assert Enum.all?(list, fn d -> match?(%Descriptor{domain: :calendar}, d) end)
    end

    test "lists video providers" do
      list = Directory.list(:video)
      assert is_list(list)
      assert list != []
      assert Enum.all?(list, fn d -> match?(%Descriptor{domain: :video}, d) end)
    end
  end

  describe "get/2" do
    test "returns descriptor for valid provider" do
      assert %Descriptor{type: :google} = Directory.get(:calendar, :google)
    end

    test "returns error for invalid provider" do
      assert {:error, :unknown_provider} = Directory.get(:calendar, :invalid)
    end
  end

  describe "helpers" do
    test "config_schema/2 returns schema" do
      assert is_map(Directory.config_schema(:calendar, :google))
    end

    test "oauth?/2 returns boolean" do
      assert Directory.oauth?(:calendar, :google) == true
      assert Directory.oauth?(:calendar, :caldav) == false
    end

    test "default_provider/1 returns atom" do
      assert is_atom(Directory.default_provider(:calendar))
      assert is_atom(Directory.default_provider(:video))
    end
  end
end
