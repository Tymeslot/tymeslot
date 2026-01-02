defmodule Tymeslot.Integrations.Calendar.CrossProviderTest do
  use ExUnit.Case, async: true

  import Tymeslot.CrossProviderTestHelpers
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  @moduledoc """
  Cross-provider consistency tests for calendar integrations.

  Ensures all calendar providers implement required behavior callbacks
  and handle operations consistently.
  """

  # List of providers to test (excluding debug/demo providers)
  @production_providers [:caldav, :nextcloud, :radicale]

  # Get production providers from registry (exclude debug/demo)
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
    test "all CalDAV-based providers have base_url field" do
      caldav_providers = [:caldav, :nextcloud, :radicale]

      Enum.each(caldav_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        schema = provider_module.config_schema()

        # CalDAV providers should have base_url
        assert Map.has_key?(schema, :base_url)
        assert schema[:base_url][:type] == :string
        assert schema[:base_url][:required] == true
      end)
    end

    test "all credential-based providers have username and password fields" do
      credential_providers = [:caldav, :nextcloud, :radicale]

      Enum.each(credential_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        schema = provider_module.config_schema()

        # Should have username
        assert Map.has_key?(schema, :username)
        assert schema[:username][:type] == :string

        # Should have password
        assert Map.has_key?(schema, :password)
        assert schema[:password][:type] == :string
      end)
    end

    test "all credential-based providers have calendar_paths field" do
      credential_providers = [:caldav, :nextcloud, :radicale]

      Enum.each(credential_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        schema = provider_module.config_schema()

        # Should have calendar_paths
        assert Map.has_key?(schema, :calendar_paths)
      end)
    end
  end

  describe "connection validation consistency" do
    test "test_connection returns error for invalid credentials" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        invalid_config = %{
          base_url: "http://localhost:1",
          username: "invalid",
          password: "invalid",
          calendar_paths: []
        }

        result = provider_module.test_connection(invalid_config)

        # Should return error tuple
        assert match?({:error, _}, result)
      end)
    end

    test "test_connection accepts metadata options" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        config = %{
          base_url: "http://localhost:1",
          username: "test",
          password: "test",
          calendar_paths: []
        }

        opts = [metadata: %{ip: "127.0.0.1"}]

        # Should not crash with options
        result = provider_module.test_connection(config, opts)

        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end)
    end
  end

  describe "client creation consistency" do
    test "new/1 creates client for credential-based providers" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        config = %{
          base_url: "http://localhost:1",
          username: "test",
          password: "test",
          calendar_paths: []
        }

        client = provider_module.new(config)

        # Client should be a map
        assert is_map(client)

        # Should have provider field
        assert Map.has_key?(client, :provider)
      end)
    end
  end

  describe "provider behavior consistency" do
    test "all providers handle network errors gracefully" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        config = %{
          base_url: "http://localhost:1",
          username: "test",
          password: "test",
          calendar_paths: []
        }

        # Should not crash on network error
        result = provider_module.test_connection(config)

        assert match?({:error, _}, result) or match?({:ok, _}, result)
      end)
    end

    test "all providers return consistent error format" do
      Enum.each(@production_providers, fn provider_type ->
        {:ok, provider_module} = ProviderRegistry.get_provider(provider_type)

        invalid_config = %{
          base_url: "http://localhost:1",
          username: "invalid",
          password: "invalid",
          calendar_paths: []
        }

        result = provider_module.test_connection(invalid_config)

        case result do
          {:error, message} ->
            # Message should be string or atom
            assert is_binary(message) or is_atom(message)

          {:ok, _} ->
            # Some providers may handle this differently
            :ok
        end
      end)
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
  end
end
