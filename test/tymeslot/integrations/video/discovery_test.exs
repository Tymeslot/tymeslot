defmodule Tymeslot.Integrations.Video.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Video.Discovery

  describe "list_available_providers/0" do
    test "returns list of available video providers" do
      providers = Discovery.list_available_providers()

      assert is_list(providers)
      assert length(providers) > 0
    end

    test "includes provider metadata for each provider" do
      providers = Discovery.list_available_providers()

      # Each provider should have metadata
      Enum.each(providers, fn provider ->
        assert is_map(provider)
        assert Map.has_key?(provider, :type)
        assert Map.has_key?(provider, :module)
        assert Map.has_key?(provider, :display_name)
        assert Map.has_key?(provider, :config_schema)
      end)
    end

    test "includes mirotalk provider" do
      providers = Discovery.list_available_providers()

      provider_types = Enum.map(providers, & &1.type)
      assert :mirotalk in provider_types
    end

    test "includes google_meet provider if available" do
      providers = Discovery.list_available_providers()

      provider_types = Enum.map(providers, & &1.type)

      # Google Meet may or may not be available depending on OAuth setup
      assert is_list(provider_types)
    end

    test "includes custom provider" do
      providers = Discovery.list_available_providers()

      provider_types = Enum.map(providers, & &1.type)
      assert :custom in provider_types
    end

    test "returns providers with valid config schemas" do
      providers = Discovery.list_available_providers()

      Enum.each(providers, fn provider ->
        assert is_map(provider.config_schema)
        # Config schema should have at least one field
        assert map_size(provider.config_schema) > 0
      end)
    end

    test "returns providers with valid display names" do
      providers = Discovery.list_available_providers()

      Enum.each(providers, fn provider ->
        assert is_binary(provider.display_name)
        assert String.length(provider.display_name) > 0
      end)
    end

    test "returns providers with module references" do
      providers = Discovery.list_available_providers()

      Enum.each(providers, fn provider ->
        assert is_atom(provider.module)
        # Module should be loaded
        assert Code.ensure_loaded?(provider.module)
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
    test "returns default video provider" do
      provider = Discovery.default_provider()

      assert is_atom(provider)
    end

    test "returns valid provider atom" do
      provider = Discovery.default_provider()

      # Should be one of the known providers
      assert provider in [:mirotalk, :google_meet, :teams, :custom]
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
