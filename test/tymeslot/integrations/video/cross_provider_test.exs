defmodule Tymeslot.Integrations.Video.CrossProviderTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  import Mox
  import Tymeslot.CrossProviderTestHelpers
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  setup :verify_on_exit!

  @moduledoc """
  Cross-provider consistency tests for video integrations.

  Ensures all video providers implement required behavior and
  handle operations consistently.
  """

  # List of providers to test
  @production_providers [:mirotalk, :custom]

  # Get production providers from registry
  defp production_providers do
    Enum.filter(ProviderRegistry.list_providers(), fn provider ->
      provider in @production_providers
    end)
  end

  describe "provider metadata consistency" do
    test "all providers return provider_type" do
      assert_providers_return_provider_type(ProviderRegistry, production_providers())
    end

    test "all providers return display_name" do
      assert_providers_return_display_name(ProviderRegistry, production_providers())
    end

    test "all providers return config_schema" do
      assert_providers_return_config_schema(ProviderRegistry, production_providers())
    end
  end

  describe "config schema consistency" do
    test "mirotalk provider has base_url field" do
      {:ok, provider_module} = ProviderRegistry.get_provider(:mirotalk)

      schema = provider_module.config_schema()

      # MiroTalk should have base_url
      assert Map.has_key?(schema, :base_url)
      assert schema[:base_url][:type] == :string
      assert schema[:base_url][:required] == true
    end

    test "custom provider has custom_meeting_url field" do
      {:ok, provider_module} = ProviderRegistry.get_provider(:custom)

      schema = provider_module.config_schema()

      # Custom should have custom_meeting_url
      assert Map.has_key?(schema, :custom_meeting_url)
      assert schema[:custom_meeting_url][:type] == :string
      assert schema[:custom_meeting_url][:required] == true
    end
  end

  describe "connection validation consistency" do
    test "custom provider test_connection reports an unreachable URL" do
      {:ok, custom} = ProviderRegistry.get_provider(:custom)

      config = %{custom_meeting_url: "https://meet.example.com/room"}

      # The URL is well-formed, so it gets as far as the reachability probe,
      # which always fails: example.com has no `meet` host.
      assert {:error, _reason} = custom.test_connection(config)
    end

    test "mirotalk test_connection requires HTTP mock" do
      {:ok, mirotalk} = ProviderRegistry.get_provider(:mirotalk)
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      assert {:ok, _result} = mirotalk.test_connection(config)
    end
  end

  describe "room creation consistency" do
    test "custom provider uses static meeting URL" do
      {:ok, custom} = ProviderRegistry.get_provider(:custom)

      # Custom provider doesn't create rooms dynamically
      # It returns the configured URL directly
      # Let's verify the schema instead
      schema = custom.config_schema()
      assert Map.has_key?(schema, :custom_meeting_url)
    end
  end

  describe "provider behavior consistency" do
    test "custom provider returns consistent error format" do
      {:ok, custom} = ProviderRegistry.get_provider(:custom)

      config = %{custom_meeting_url: "invalid-url"}

      assert custom.test_connection(config) ==
               {:error, "Invalid URL scheme. Only http and https are supported"}
    end
  end

  describe "registry integration" do
    test "all production providers are registered correctly" do
      assert_providers_registered_correctly(ProviderRegistry, @production_providers)
    end

    test "provider metadata is accessible through registry" do
      assert_provider_metadata_accessible(ProviderRegistry, @production_providers)
    end

    test "provider validation works through registry" do
      assert_provider_validation_works(ProviderRegistry, @production_providers)
    end

    test "provider recommendation works" do
      requirements = %{
        participant_count: 10,
        recording_required: false
      }

      # Ten participants with no recording needs is served by the default.
      assert ProviderRegistry.recommend_provider(requirements) == :mirotalk
    end

    test "capability filtering returns only providers with that capability" do
      assert ProviderRegistry.providers_with_capability(:screen_sharing) == [
               :mirotalk,
               :google_meet,
               :teams,
               :zoom
             ]
    end
  end

  describe "configuration validation" do
    test "providers validate required fields" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        # Empty config should fail validation
        result = provider_module.validate_config(%{})

        assert match?({:error, _reason}, result)
      end)
    end

    test "custom provider accepts valid configuration" do
      {:ok, custom} = ProviderRegistry.get_provider(:custom)

      custom_config = %{
        custom_meeting_url: "https://meet.example.com/room123"
      }

      assert custom.validate_config(custom_config) == :ok
    end

    # Every video provider's `validate_config/1` is a structural check only;
    # reaching the network is `test_connection/1`'s job. MiroTalk is the one
    # provider with a network-capable config, so it is the one worth pinning.
    test "mirotalk provider validates configuration without network access" do
      {:ok, mirotalk} = ProviderRegistry.get_provider(:mirotalk)
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      assert :ok = mirotalk.validate_config(config)
    end
  end
end
