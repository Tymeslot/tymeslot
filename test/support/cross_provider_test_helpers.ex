defmodule Tymeslot.CrossProviderTestHelpers do
  @moduledoc """
  Shared test helpers for cross-provider consistency testing.

  Provides common test assertions for both calendar and video provider registries.
  """

  import ExUnit.Assertions

  @doc """
  Tests that all providers return provider_type correctly.
  """
  @spec assert_providers_return_provider_type(module(), list(atom())) :: :ok
  def assert_providers_return_provider_type(registry_module, provider_list) do
    Enum.each(provider_list, fn provider_type ->
      {:ok, provider_module} = registry_module.get_provider(provider_type)

      # Should be able to call provider_type
      result = provider_module.provider_type()
      assert is_atom(result)
      assert result == provider_type
    end)

    :ok
  end

  @doc """
  Tests that all providers return display_name.
  """
  @spec assert_providers_return_display_name(module(), list(atom())) :: :ok
  def assert_providers_return_display_name(registry_module, provider_list) do
    Enum.each(provider_list, fn provider_type ->
      {:ok, provider_module} = registry_module.get_provider(provider_type)

      # Should be able to call display_name
      display_name = provider_module.display_name()
      assert is_binary(display_name)
      assert String.length(display_name) > 0
    end)

    :ok
  end

  @doc """
  Tests that all providers return config_schema.
  """
  @spec assert_providers_return_config_schema(module(), list(atom())) :: :ok
  def assert_providers_return_config_schema(registry_module, provider_list) do
    Enum.each(provider_list, fn provider_type ->
      {:ok, provider_module} = registry_module.get_provider(provider_type)

      # Should be able to call config_schema
      schema = provider_module.config_schema()
      assert is_map(schema)
      assert map_size(schema) > 0
    end)

    :ok
  end

  @doc """
  Tests that all production providers are registered correctly.
  """
  @spec assert_providers_registered_correctly(module(), list(atom())) :: :ok
  def assert_providers_registered_correctly(registry_module, production_providers) do
    Enum.each(production_providers, fn provider_type ->
      # Should be able to get provider
      assert {:ok, module} = registry_module.get_provider(provider_type)
      assert is_atom(module)

      # Module should be loaded
      assert Code.ensure_loaded?(module)
    end)

    :ok
  end

  @doc """
  Tests that provider metadata is accessible through registry.
  """
  @spec assert_provider_metadata_accessible(module(), list(atom())) :: :ok
  def assert_provider_metadata_accessible(registry_module, production_providers) do
    providers_with_metadata = registry_module.list_providers_with_metadata()

    # Should include our production providers
    provider_types = Enum.map(providers_with_metadata, & &1.type)

    Enum.each(production_providers, fn provider_type ->
      assert provider_type in provider_types
    end)

    # Each should have metadata
    Enum.each(providers_with_metadata, fn provider ->
      assert Map.has_key?(provider, :type)
      assert Map.has_key?(provider, :module)
      assert Map.has_key?(provider, :display_name)
      assert Map.has_key?(provider, :config_schema)
    end)

    :ok
  end

  @doc """
  Tests that provider validation works through registry.
  """
  @spec assert_provider_validation_works(module(), list(atom())) :: :ok
  def assert_provider_validation_works(registry_module, production_providers) do
    Enum.each(production_providers, fn provider_type ->
      assert registry_module.valid_provider?(provider_type)
    end)

    :ok
  end
end
