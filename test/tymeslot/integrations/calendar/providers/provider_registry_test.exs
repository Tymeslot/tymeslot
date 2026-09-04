defmodule Tymeslot.Integrations.Calendar.Providers.ProviderRegistryTest do
  use Tymeslot.MockCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  describe "list_providers/0" do
    test "returns list of all registered providers" do
      providers = ProviderRegistry.list_providers()

      assert :caldav in providers
      assert :google in providers
      assert :nextcloud in providers
      assert :radicale in providers
      # Outlook may not be enabled in all environments
    end

    test "lists the development-only providers alongside the production ones" do
      providers = ProviderRegistry.list_providers()

      # list_providers/0 reports the registry's static map, so the dev-only
      # providers appear here even when valid_providers/0 filters them out.
      assert :debug in providers
      assert :demo in providers
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

    test "returns provider module for valid outlook provider" do
      # :outlook is statically registered and get_provider/1 is toggle-agnostic,
      # so this resolves regardless of the runtime enable flag.
      assert ProviderRegistry.get_provider(:outlook) ==
               {:ok, Tymeslot.Integrations.Calendar.Outlook.Provider}
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

      assert message == "Unknown provider type: :unknown"
    end

    test "returns {:ok, module} for a provider that is disabled in config (toggle-agnostic)" do
      previous = Application.get_env(:tymeslot, :calendar_providers)

      Application.put_env(
        :tymeslot,
        :calendar_providers,
        Map.put(previous, :caldav, enabled: false)
      )

      on_exit(fn -> Application.put_env(:tymeslot, :calendar_providers, previous) end)

      assert ProviderRegistry.get_provider(:caldav) ==
               {:ok, Tymeslot.Integrations.Calendar.CalDAV.Provider}
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

      assert :caldav in providers
      assert :google in providers
      assert :nextcloud in providers
      assert :radicale in providers
      # Outlook may not be enabled in all environments
    end

    test "reports only providers that are enabled at runtime" do
      valid = ProviderRegistry.valid_providers()
      registered = ProviderRegistry.list_providers()

      assert valid != []

      assert Enum.all?(valid, &(&1 in registered)),
             "valid_providers/0 must be a subset of the registered providers"

      # Registered, but not enabled in the test environment.
      refute :debug in valid
    end
  end

  describe "validate_provider_config/2" do
    # `validate_config/1` is structural only — it never performs network I/O,
    # so a structurally complete config passes without touching the network.
    test "delegates validation to provider module for caldav" do
      config = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass"
      }

      result = ProviderRegistry.validate_provider_config(:caldav, config)
      assert result == :ok
    end

    test "validates missing required fields" do
      config = %{base_url: "https://example.com"}

      result = ProviderRegistry.validate_provider_config(:caldav, config)
      assert {:error, _message} = result
    end

    test "returns error for unknown provider type" do
      config = %{}

      assert {:error, _reason} = ProviderRegistry.validate_provider_config(:unknown, config)
    end
  end

  describe "list_providers_with_metadata/0" do
    test "returns metadata for all providers" do
      providers = ProviderRegistry.list_providers_with_metadata()

      assert length(providers) == ProviderRegistry.provider_count()

      # Check metadata structure
      assert provider = Enum.find(providers, fn p -> p.type == :caldav end)
      assert provider.module == Tymeslot.Integrations.Calendar.CalDAV.Provider
      assert provider.display_name == "CalDAV"

      assert %{
               base_url: %{type: :string, required: true},
               username: %{type: :string, required: true},
               password: %{type: :string, required: true}
             } = provider.config_schema
    end

    test "includes config schema for each provider" do
      providers = ProviderRegistry.list_providers_with_metadata()

      Enum.each(providers, fn provider ->
        # Each provider should have at least one field in the schema
        assert map_size(provider.config_schema) > 0
      end)
    end
  end

  describe "the registry map and ProviderConfig.get_provider_module/1" do
    # Two hand-maintained provider-to-module tables, and nothing has ever
    # asked them to agree. They are not interchangeable at runtime:
    # ProviderAdapter resolves a persisted integration through the registry,
    # while the validate-then-test path in Calendar.Creation resolves the same
    # provider through ProviderConfig. A table that drifts sends the two down
    # different modules for one provider, and neither side raises.
    #
    # `list_providers_with_metadata/0` is used rather than `get_provider/1`
    # because the calendar registry overrides `get_provider/1` to delegate to
    # ProviderConfig — asking it would compare ProviderConfig with itself.
    test "resolve every provider to the same module" do
      registry_modules =
        Map.new(ProviderRegistry.list_providers_with_metadata(), fn %{type: type, module: module} ->
          {type, module}
        end)

      config_modules =
        Map.new(config_providers(), fn provider ->
          {provider, ProviderConfig.get_provider_module(provider)}
        end)

      assert registry_modules != %{}
      assert config_modules != %{}
      assert registry_modules == config_modules
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
      # Nothing else in this file pins the registry's full contents — the
      # list_providers/0 tests only assert membership — so a provider silently
      # dropped from the registry would otherwise go unnoticed here.
      assert Enum.sort(ProviderRegistry.list_providers()) == [
               :apple,
               :baikal,
               :caldav,
               :debug,
               :demo,
               :exchange,
               :google,
               :ics_url,
               :mailbox_org,
               :nextcloud,
               :outlook,
               :radicale,
               :zimbra
             ]

      assert ProviderRegistry.provider_count() == 13
    end
  end

  describe "create_client/3" do
    # `validate_config/1` is structural only — it never performs network I/O,
    # so a structurally complete config passes validation and the client is
    # built.
    test "creates client with validation for caldav" do
      config = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      result = ProviderRegistry.create_client(:caldav, config)
      assert match?({:ok, _client}, result)
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

      assert {:error, _reason} = ProviderRegistry.create_client(:unknown, config)
    end

    test "validates config structure before client creation" do
      # Missing required fields
      config = %{base_url: "https://example.com"}

      result = ProviderRegistry.create_client(:caldav, config)
      assert {:error, _reason} = result
    end
  end

  # `provider_constraint_list/0` rather than `valid_providers/0`: the latter is
  # filtered by the runtime toggles, so a provider pinned off in config would
  # drop out of the comparison and take any drift with it.
  defp config_providers do
    Enum.map(ProviderConfig.provider_constraint_list(), fn name ->
      {:ok, provider} = ProviderConfig.parse_known(name)
      provider
    end)
  end
end
