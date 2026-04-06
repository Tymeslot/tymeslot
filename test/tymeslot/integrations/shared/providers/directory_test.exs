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

  describe "format_provider_name/2" do
    test "returns display name for a known atom provider" do
      assert Directory.format_provider_name(:calendar, :google) == "Google Calendar"
    end

    test "returns display name for a known string provider" do
      assert Directory.format_provider_name(:calendar, "google") == "Google Calendar"
    end

    test "returns capitalised fallback for unknown provider" do
      assert Directory.format_provider_name(:calendar, "nonexistent_thing") ==
               "Nonexistent thing"
    end

    test "returns capitalised fallback for unknown atom provider" do
      assert Directory.format_provider_name(:video, :nonexistent) == "Nonexistent"
    end
  end

  describe "oauth?/2" do
    test "returns boolean for atom provider" do
      assert Directory.oauth?(:calendar, :google) == true
      assert Directory.oauth?(:calendar, :caldav) == false
    end

    test "returns boolean for string provider" do
      assert Directory.oauth?(:calendar, "google") == true
      assert Directory.oauth?(:calendar, "caldav") == false
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} = Directory.oauth?(:calendar, "nonexistent")
      assert {:error, :unknown_provider} = Directory.oauth?(:calendar, :nonexistent)
    end
  end

  describe "helpers" do
    test "config_schema/2 returns schema" do
      assert is_map(Directory.config_schema(:calendar, :google))
    end

    test "default_provider/1 returns atom" do
      assert is_atom(Directory.default_provider(:calendar))
      assert is_atom(Directory.default_provider(:video))
    end
  end
end
