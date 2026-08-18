defmodule Tymeslot.Integrations.Video.DiscoveryTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Discovery

  describe "list_available_providers/0" do
    test "returns list of available video providers" do
      providers = Discovery.list_available_providers()

      assert Enum.sort(Enum.map(providers, & &1.type)) ==
               [:custom, :google_meet, :mirotalk, :teams, :zoom]
    end

    test "includes provider metadata for each provider" do
      providers = Discovery.list_available_providers()

      # Each provider should have metadata
      Enum.each(providers, fn provider ->
        assert %{
                 type: _type,
                 module: _module,
                 display_name: _display_name,
                 config_schema: _config_schema
               } = provider
      end)
    end

    test "returns providers with valid config schemas" do
      providers = Discovery.list_available_providers()

      Enum.each(providers, fn provider ->
        # Config schema should have at least one field
        assert map_size(provider.config_schema) > 0,
               "#{provider.type} has an empty config schema"
      end)
    end

    test "returns providers with valid display names" do
      providers = Discovery.list_available_providers()

      Enum.each(providers, fn provider ->
        assert String.length(provider.display_name) > 0,
               "#{provider.type} has a blank display name"
      end)
    end

    test "returns providers with module references" do
      providers = Discovery.list_available_providers()

      Enum.each(providers, fn provider ->
        # Module should be loaded
        assert Code.ensure_loaded?(provider.module),
               "#{provider.type} points at unloadable module #{inspect(provider.module)}"
      end)
    end
  end

  describe "default_provider/0" do
    test "returns mirotalk as the default video provider" do
      assert Discovery.default_provider() == :mirotalk
    end
  end
end
