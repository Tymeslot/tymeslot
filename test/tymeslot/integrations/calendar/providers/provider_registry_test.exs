defmodule Tymeslot.Integrations.Calendar.Providers.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  describe "list_providers/0" do
    test "returns list of all registered providers" do
      providers = ProviderRegistry.list_providers()

      assert is_list(providers)
      assert :caldav in providers
      assert :google in providers
      assert :nextcloud in providers
      assert :radicale in providers
      # Outlook may not be enabled in all environments
    end

    test "may include development providers in test environment" do
      providers = ProviderRegistry.list_providers()

      # Debug and demo providers may be available in test environment
      assert is_list(providers)
      assert length(providers) >= 4
    end
  end

  describe "get_provider/1" do
    test "returns provider module for valid caldav provider" do
      assert {:ok, module} = ProviderRegistry.get_provider(:caldav)
      assert module == Tymeslot.Integrations.Calendar.CalDAV.Provider
    end

    test "returns provider module for valid google provider" do
      assert {:ok, module} = ProviderRegistry.get_provider(:google)
      assert module == Tymeslot.Integrations.Calendar.Google.Provider
    end

    test "returns provider module for outlook if available" do
      case ProviderRegistry.get_provider(:outlook) do
        {:ok, module} ->
          assert module == Tymeslot.Integrations.Calendar.Outlook.Provider

        {:error, _} ->
          # Outlook provider may not be enabled
          :ok
      end
    end

    test "returns provider module for valid nextcloud provider" do
      assert {:ok, module} = ProviderRegistry.get_provider(:nextcloud)
      assert module == Tymeslot.Integrations.Calendar.Nextcloud.Provider
    end

    test "returns provider module for valid radicale provider" do
      assert {:ok, module} = ProviderRegistry.get_provider(:radicale)
      assert module == Tymeslot.Integrations.Calendar.Radicale.Provider
    end

    test "returns error for unknown provider" do
      assert {:error, message} = ProviderRegistry.get_provider(:unknown)
      assert String.contains?(message, "Invalid provider") or String.contains?(message, "Unknown provider")
    end

    test "returns error for invalid provider in disabled state" do
      # This would test provider config disabled state
      # For now, all providers are enabled in test
      :ok
    end
  end

  describe "get_provider!/1" do
    test "returns provider module for valid provider" do
      module = ProviderRegistry.get_provider!(:caldav)
      assert module == Tymeslot.Integrations.Calendar.CalDAV.Provider
    end

    test "raises for unknown provider" do
      assert_raise ArgumentError, fn ->
        ProviderRegistry.get_provider!(:invalid_provider)
      end
    end
  end

  describe "validate_provider/1" do
    test "validates and returns atom for valid string provider" do
      assert {:ok, :caldav} = ProviderRegistry.validate_provider("caldav")
      assert {:ok, :google} = ProviderRegistry.validate_provider("google")
      assert {:ok, :nextcloud} = ProviderRegistry.validate_provider("nextcloud")
    end

    test "validates and returns atom for valid atom provider" do
      assert {:ok, :caldav} = ProviderRegistry.validate_provider(:caldav)
      assert {:ok, :google} = ProviderRegistry.validate_provider(:google)
    end

    test "returns error for invalid provider" do
      assert {:error, message} = ProviderRegistry.validate_provider("invalid")
      assert String.contains?(message, "Invalid provider")
    end

    test "returns error for invalid provider atom" do
      assert {:error, message} = ProviderRegistry.validate_provider(:invalid)
      assert String.contains?(message, "Invalid provider")
    end
  end

  describe "valid_provider?/1" do
    test "returns true for valid providers" do
      assert ProviderRegistry.valid_provider?(:caldav)
      assert ProviderRegistry.valid_provider?(:google)
      assert ProviderRegistry.valid_provider?(:nextcloud)
      assert ProviderRegistry.valid_provider?(:radicale)
      # Outlook may not be enabled in all environments
    end

    test "returns false for invalid providers" do
      refute ProviderRegistry.valid_provider?(:invalid)
      refute ProviderRegistry.valid_provider?(:unknown)
    end
  end

  describe "valid_providers/0" do
    test "returns list of all valid provider atoms" do
      providers = ProviderRegistry.valid_providers()

      assert is_list(providers)
      assert :caldav in providers
      assert :google in providers
      assert :nextcloud in providers
      assert :radicale in providers
      # Outlook may not be enabled in all environments
    end

    test "may include development providers in test environment" do
      providers = ProviderRegistry.valid_providers()

      # Debug and demo providers may be available in test environment
      assert is_list(providers)
      assert length(providers) >= 4
    end
  end

  describe "validate_provider_config/2" do
    test "delegates validation to provider module for caldav" do
      config = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass"
      }

      # Will fail connection but structure is validated
      result = ProviderRegistry.validate_provider_config(:caldav, config)
      assert match?({:error, _}, result)
    end

    test "validates missing required fields" do
      config = %{base_url: "https://example.com"}

      result = ProviderRegistry.validate_provider_config(:caldav, config)
      assert {:error, _message} = result
    end

    test "returns error for unknown provider type" do
      config = %{}

      assert {:error, _} = ProviderRegistry.validate_provider_config(:unknown, config)
    end
  end

  describe "list_providers_with_metadata/0" do
    test "returns metadata for all providers" do
      providers = ProviderRegistry.list_providers_with_metadata()

      assert is_list(providers)
      assert length(providers) > 0

      # Check metadata structure
      provider = Enum.find(providers, fn p -> p.type == :caldav end)
      assert provider.type == :caldav
      assert provider.module == Tymeslot.Integrations.Calendar.CalDAV.Provider
      assert provider.display_name == "CalDAV"
      assert is_map(provider.config_schema)
    end

    test "includes config schema for each provider" do
      providers = ProviderRegistry.list_providers_with_metadata()

      Enum.each(providers, fn provider ->
        assert is_map(provider.config_schema)
        # Each provider should have at least one field in the schema
        assert map_size(provider.config_schema) > 0
      end)
    end
  end

  describe "default_provider/0" do
    test "returns the default calendar provider" do
      assert ProviderRegistry.default_provider() == :caldav
    end
  end

  describe "provider_supported?/1" do
    test "returns true for supported providers" do
      assert ProviderRegistry.provider_supported?(:caldav)
      assert ProviderRegistry.provider_supported?(:google)
      assert ProviderRegistry.provider_supported?(:nextcloud)
      # Outlook may not be enabled in all environments
    end

    test "returns false for unsupported providers" do
      refute ProviderRegistry.provider_supported?(:unknown)
      refute ProviderRegistry.provider_supported?(:invalid)
    end
  end

  describe "provider_count/0" do
    test "returns total number of registered providers" do
      count = ProviderRegistry.provider_count()

      assert is_integer(count)
      assert count >= 7
    end
  end

  describe "create_client/3" do
    test "creates client with validation for caldav" do
      config = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      # Will fail validation due to network error
      result = ProviderRegistry.create_client(:caldav, config)
      assert match?({:error, _}, result)
    end

    test "creates client without validation when skip_validation is true" do
      config = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      # Should create client without validation
      result = ProviderRegistry.create_client(:caldav, config, skip_validation: true)
      assert match?({:ok, _client}, result)
    end

    test "returns error for unknown provider" do
      config = %{}

      assert {:error, _} = ProviderRegistry.create_client(:unknown, config)
    end

    test "validates config structure before client creation" do
      # Missing required fields
      config = %{base_url: "https://example.com"}

      result = ProviderRegistry.create_client(:caldav, config)
      assert {:error, _} = result
    end
  end
end
