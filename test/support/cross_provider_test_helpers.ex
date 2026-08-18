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
  Tests that every provider returns the display name the caller expects.

  `expected_names` maps a provider type to the exact label the UI renders for
  it. Pinning the label is the point: a non-empty string tells you nothing,
  while a swapped or lower-cased name is exactly the regression this catches.
  """
  @spec assert_providers_return_display_name(module(), %{atom() => String.t()}) :: :ok
  def assert_providers_return_display_name(registry_module, expected_names)
      when is_map(expected_names) do
    Enum.each(expected_names, fn {provider_type, expected_name} ->
      {:ok, provider_module} = registry_module.get_provider(provider_type)

      assert provider_module.display_name() == expected_name
    end)

    :ok
  end

  # Every declared field type the form renderer knows how to handle.
  @known_field_types [:string, :integer, :boolean, :list, :map]

  @doc """
  Tests that every provider's config schema declares each field the way the
  setup form needs it: a `:type` the renderer understands and an explicit
  `:required` flag, with at least one field actually required.

  A schema that merely is a non-empty map satisfies nothing — a field missing
  `:required` renders as optional and silently lets an incomplete config
  through.
  """
  @spec assert_providers_return_config_schema(module(), list(atom())) :: :ok
  def assert_providers_return_config_schema(registry_module, provider_list) do
    Enum.each(provider_list, fn provider_type ->
      {:ok, provider_module} = registry_module.get_provider(provider_type)

      schema = provider_module.config_schema()
      assert is_map(schema) and map_size(schema) > 0

      Enum.each(schema, fn {field, definition} ->
        context = "#{inspect(provider_type)}.#{field}"

        assert definition[:type] in @known_field_types,
               "#{context} declares an unknown field type: #{inspect(definition[:type])}"

        assert is_boolean(definition[:required]),
               "#{context} must declare :required explicitly"
      end)

      assert Enum.any?(schema, fn {_field, definition} -> definition[:required] end),
             "#{inspect(provider_type)} declares no required config field"
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
