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

    test "includes mirotalk provider" do
      providers = Discovery.list_available_providers()

      provider_types = Enum.map(providers, & &1.type)
      assert :mirotalk in provider_types
    end

    test "includes google_meet provider" do
      providers = Discovery.list_available_providers()

      provider_types = Enum.map(providers, & &1.type)
      assert :google_meet in provider_types
    end

    test "includes custom provider" do
      providers = Discovery.list_available_providers()

      provider_types = Enum.map(providers, & &1.type)
      assert :custom in provider_types
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

    test "returns consistent provider list on multiple calls" do
      providers1 = Discovery.list_available_providers()
      providers2 = Discovery.list_available_providers()

      # Should return same providers
      types1 = Enum.sort(Enum.map(providers1, & &1.type))
      types2 = Enum.sort(Enum.map(providers2, & &1.type))

      assert types1 == types2
    end
  end

  describe "default_provider/0" do
    test "returns mirotalk as the default video provider" do
      assert Discovery.default_provider() == :mirotalk
    end

    test "default provider is in available providers list" do
      default = Discovery.default_provider()
      providers = Discovery.list_available_providers()

      provider_types = Enum.map(providers, & &1.type)
      assert default in provider_types
    end

    test "returns consistent default on multiple calls" do
      default1 = Discovery.default_provider()
      default2 = Discovery.default_provider()

      assert default1 == default2
    end
  end
end
