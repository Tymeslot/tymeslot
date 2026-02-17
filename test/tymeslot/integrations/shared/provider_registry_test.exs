defmodule Tymeslot.Integrations.Common.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Common.ProviderRegistry

  # Mock provider modules for testing the macro
  defmodule MockGoogleProvider do
    @spec provider_type() :: :google
    def provider_type, do: :google

    @spec display_name() :: String.t()
    def display_name, do: "Google"

    @spec config_schema() :: map()
    def config_schema, do: %{key: :string}

    @spec validate_config(map()) :: :ok | {:error, String.t()}
    def validate_config(_arg), do: :ok

    @spec capabilities() :: [atom()]
    def capabilities, do: [:events]
  end

  defmodule MockOutlookProvider do
    @spec provider_type() :: :outlook
    def provider_type, do: :outlook

    @spec display_name() :: String.t()
    def display_name, do: "Outlook"

    @spec config_schema() :: map()
    def config_schema, do: %{key: :string}

    @spec validate_config(map()) :: :ok | {:error, String.t()}
    def validate_config(_arg), do: :ok
  end

  defmodule TestRegistry do
    use Tymeslot.Integrations.Common.ProviderRegistry,
      provider_type_name: "test provider",
      default_provider: :google,
      metadata_fields: [:capabilities],
      providers: %{
        google: MockGoogleProvider,
        outlook: MockOutlookProvider
      }
  end

  describe "macro-generated functions" do
    test "list_providers/0 returns all types" do
      assert Enum.sort(TestRegistry.list_providers()) == [:google, :outlook]
    end

    test "get_provider/1 returns module or error" do
      assert {:ok, MockGoogleProvider} = TestRegistry.get_provider(:google)
      assert {:error, "Unknown test provider type: invalid"} = TestRegistry.get_provider(:invalid)
    end

    test "get_provider!/1 returns module or raises" do
      assert TestRegistry.get_provider!(:google) == MockGoogleProvider
      assert_raise ArgumentError, fn -> TestRegistry.get_provider!(:invalid) end
    end

    test "validate_provider_config/2 delegates to module" do
      assert :ok = TestRegistry.validate_provider_config(:google, %{})
    end

    test "list_providers_with_metadata/0 returns full info" do
      metadata = TestRegistry.list_providers_with_metadata()
      google = Enum.find(metadata, &(&1.type == :google))

      assert google.display_name == "Google"
      assert google.capabilities == [:events]

      outlook = Enum.find(metadata, &(&1.type == :outlook))
      assert outlook.capabilities == []
    end

    test "default_provider/0 returns default" do
      assert TestRegistry.default_provider() == :google
    end

    test "provider_supported?/1 checks existence" do
      assert TestRegistry.provider_supported?(:google)
      refute TestRegistry.provider_supported?(:invalid)
    end

    test "provider_count/0 returns size" do
      assert TestRegistry.provider_count() == 2
    end
  end

  describe "create_provider_map/1" do
    test "builds map from modules" do
      map = ProviderRegistry.create_provider_map([MockGoogleProvider, MockOutlookProvider])
      assert map == %{google: MockGoogleProvider, outlook: MockOutlookProvider}
    end
  end

  describe "validate_provider_implementations/2" do
    test "returns :ok when all functions exist" do
      providers = %{google: MockGoogleProvider}

      assert :ok =
               ProviderRegistry.validate_provider_implementations(providers, [
                 {:display_name, 0},
                 {:config_schema, 0}
               ])
    end

    test "returns error when functions are missing" do
      providers = %{google: MockGoogleProvider}

      assert {:error, {:missing_functions, [{:google, MockGoogleProvider, [missing: 0]}]}} =
               ProviderRegistry.validate_provider_implementations(providers, [
                 {:missing, 0}
               ])
    end
  end
end
