defmodule Tymeslot.Integrations.Common.ProviderRegistry do
  @moduledoc """
  Generic provider registry implementation.

  This module provides a reusable registry pattern for managing different types
  of integration providers (calendar, video, etc.) with customizable behavior
  through configuration options.
  """

  # Type definitions
  @type provider_type :: atom()
  @type provider_module :: module()
  @type provider_config :: map()
  @type provider_metadata :: %{
          type: provider_type(),
          module: provider_module(),
          display_name: String.t(),
          config_schema: map()
        }

  @doc """
  Macro for creating provider registries with customizable behavior.

  ## Options

    * `:provider_type_name` - The name used in error messages (e.g., "provider", "video provider")
    * `:default_provider` - The default provider atom to use
    * `:metadata_fields` - Additional metadata fields beyond the standard ones
    * `:providers` - Map of provider type atoms to module names

  ## Example

      defmodule MyApp.CalendarRegistry do
        use Tymeslot.Integrations.Common.ProviderRegistry,
          provider_type_name: "provider",
          default_provider: :caldav,
          metadata_fields: [],
          providers: %{
            google: MyApp.GoogleProvider,
            outlook: MyApp.OutlookProvider
          }
      end
  """
  defmacro __using__(opts) do
    provider_type_name = Keyword.get(opts, :provider_type_name, "provider")
    default_provider = Keyword.get(opts, :default_provider)
    metadata_fields = Keyword.get(opts, :metadata_fields, [])
    providers = Keyword.get(opts, :providers, %{})

    quote do
      @provider_type_name unquote(provider_type_name)
      @default_provider unquote(default_provider)
      @metadata_fields unquote(metadata_fields)
      @providers unquote(providers)

      @doc """
      Returns a list of available provider types.
      """
      def list_providers do
        Map.keys(@providers)
      end

      @doc """
      Gets a provider module by type.

      Returns `{:ok, module}` if the provider exists, or `{:error, message}` if not found.
      """
      def get_provider(provider_type) do
        case Map.get(@providers, provider_type) do
          nil -> {:error, "Unknown #{@provider_type_name} type: #{provider_type}"}
          module -> {:ok, module}
        end
      end

      @doc """
      Gets a provider module by type, raising if not found.

      Returns the provider module or raises `ArgumentError` if the provider doesn't exist.
      """
      def get_provider!(provider_type) do
        case get_provider(provider_type) do
          {:ok, module} -> module
          {:error, message} -> raise ArgumentError, message
        end
      end

      @doc """
      Validates configuration for a specific provider type.

      Delegates validation to the provider module's `validate_config/1` function.
      """
      def validate_provider_config(provider_type, config) do
        case get_provider(provider_type) do
          {:ok, module} -> module.validate_config(config)
          {:error, _} = error -> error
        end
      end

      @doc """
      Returns metadata for all providers.

      Standard metadata includes: type, module, display_name, config_schema.
      Additional metadata fields can be specified in the `metadata_fields` option.
      """
      def list_providers_with_metadata do
        Enum.map(@providers, fn {type, module} ->
          base_metadata = %{
            type: type,
            module: module,
            display_name: get_provider_metadata(module, :display_name),
            config_schema: get_provider_metadata(module, :config_schema)
          }

          additional_metadata =
            Enum.reduce(@metadata_fields, %{}, fn field, acc ->
              Map.put(acc, field, get_provider_metadata(module, field))
            end)

          Map.merge(base_metadata, additional_metadata)
        end)
      end

      @doc """
      Returns the default provider type.
      """
      def default_provider do
        @default_provider
      end

      @doc """
      Checks if a provider type is supported.
      """
      def provider_supported?(provider_type) do
        Map.has_key?(@providers, provider_type)
      end

      @doc """
      Returns the total number of registered providers.
      """
      def provider_count do
        map_size(@providers)
      end

      # Private helper to safely get metadata from provider modules
      defp get_provider_metadata(module, field) do
        case field do
          :display_name ->
            module.display_name()

          :config_schema ->
            module.config_schema()

          :capabilities ->
            if function_exported?(module, :capabilities, 0), do: module.capabilities(), else: []

          _ ->
            if function_exported?(module, field, 0) do
              apply(module, field, [])
            else
              nil
            end
        end
      rescue
        _ -> nil
      end

      # Allow specific registries to override behavior if needed
      defoverridable list_providers: 0,
                     get_provider: 1,
                     get_provider!: 1,
                     validate_provider_config: 2,
                     list_providers_with_metadata: 0,
                     default_provider: 0,
                     provider_supported?: 1,
                     provider_count: 0
    end
  end

  @doc """
  Helper function to create a provider map from a list of modules.

  Automatically derives the provider type from each module's `provider_type/0` function.

  ## Example

      providers = create_provider_map([
        MyApp.GoogleProvider,
        MyApp.OutlookProvider
      ])
      # Returns: %{google: MyApp.GoogleProvider, outlook: MyApp.OutlookProvider}
  """
  @spec create_provider_map([provider_module()]) :: %{provider_type() => provider_module()}
  def create_provider_map(modules) when is_list(modules) do
    Enum.reduce(modules, %{}, fn module, acc ->
      try do
        provider_type = module.provider_type()
        Map.put(acc, provider_type, module)
      rescue
        _ -> acc
      end
    end)
  end

  @doc """
  Validates that all providers in a registry implement required functions.

  ## Example

      validate_provider_implementations(
        %{google: GoogleProvider, outlook: OutlookProvider},
        [{:display_name, 0}, {:config_schema, 0}, {:validate_config, 1}]
      )
  """
  @spec validate_provider_implementations(
          %{provider_type() => provider_module()},
          [{atom(), non_neg_integer()}]
        ) :: :ok | {:error, {:missing_functions, list()}}
  def validate_provider_implementations(providers, required_functions)
      when is_map(providers) and is_list(required_functions) do
    errors_acc =
      Enum.reduce(providers, [], fn {type, module}, errors ->
        missing_functions =
          Enum.reject(required_functions, fn {function, arity} ->
            function_exported?(module, function, arity)
          end)

        case missing_functions do
          [] -> errors
          missing -> [{type, module, missing} | errors]
        end
      end)

    case errors_acc do
      [] -> :ok
      errors -> {:error, {:missing_functions, errors}}
    end
  end
end
