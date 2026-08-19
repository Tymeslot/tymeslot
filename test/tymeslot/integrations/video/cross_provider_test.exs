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
    test "custom provider perform_connection_test reports an unreachable URL" do
      {:ok, custom} = ProviderRegistry.get_provider(:custom)

      config = %{custom_meeting_url: "https://meet.example.com/room"}

      # The URL is well-formed, so it gets as far as the reachability probe.
      # HEAD failing falls back to GET, and a transport error on both is what
      # an unreachable host looks like.
      unreachable = %Req.TransportError{reason: :nxdomain}

      expect(Tymeslot.HTTPClientMock, :head, fn _url, _headers, _opts -> {:error, unreachable} end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts -> {:error, unreachable} end)

      assert {:error, reason} = custom.perform_connection_test(config)
      assert reason =~ "Failed to reach URL"
    end

    test "mirotalk perform_connection_test requires HTTP mock" do
      {:ok, mirotalk} = ProviderRegistry.get_provider(:mirotalk)
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      assert {:ok, _result} = mirotalk.perform_connection_test(config)
    end
  end

  describe "provider behavior consistency" do
    test "custom provider returns consistent error format" do
      {:ok, custom} = ProviderRegistry.get_provider(:custom)

      config = %{custom_meeting_url: "invalid-url"}

      assert custom.perform_connection_test(config) ==
               {:error, "Invalid URL scheme. Only http and https are supported"}
    end
  end

  describe "registry integration" do
    test "all production providers are registered correctly" do
      assert_providers_registered_correctly(ProviderRegistry, @production_providers)
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
    # reaching the network is `perform_connection_test/1`'s job. MiroTalk is the one
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
