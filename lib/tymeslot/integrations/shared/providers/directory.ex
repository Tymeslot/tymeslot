defmodule Tymeslot.Integrations.Providers.Directory do
  @moduledoc """
  Single source of truth for provider metadata and utilities across domains.

  UI and services should query this module to list providers, access their
  config schemas, capabilities, OAuth support, and test connections.
  """

  alias Tymeslot.Integrations.Providers.Descriptor

  @type domain :: :calendar | :video

  @doc """
  Lists all providers for a domain with metadata descriptors.
  """
  @spec list(domain()) :: [Descriptor.t()]
  def list(domain) when domain in [:calendar, :video] do
    Enum.map(domain_provider_types(domain), &build_descriptor(domain, &1))
  end

  @doc """
  Gets a provider descriptor by domain and type.
  """
  @spec get(domain(), atom()) :: Descriptor.t() | {:error, :unknown_provider}
  def get(domain, type) when domain in [:calendar, :video] and is_atom(type) do
    if domain_valid_provider?(domain, type) do
      build_descriptor(domain, type)
    else
      {:error, :unknown_provider}
    end
  end

  @doc """
  Returns the configuration schema for a provider.
  """
  @spec config_schema(domain(), atom()) :: map() | {:error, :unknown_provider}
  def config_schema(domain, type) do
    case get(domain, type) do
      %Descriptor{config_schema: schema} -> schema
      _ -> {:error, :unknown_provider}
    end
  end

  @doc """
  Returns capabilities for a provider (may be empty map for calendar).
  """
  @spec capabilities(domain(), atom()) :: map() | {:error, :unknown_provider}
  def capabilities(domain, type) do
    case get(domain, type) do
      %Descriptor{capabilities: caps} -> caps
      _ -> {:error, :unknown_provider}
    end
  end

  @doc """
  Indicates whether a provider uses OAuth.
  """
  @spec oauth?(domain(), atom()) :: boolean() | {:error, :unknown_provider}
  def oauth?(domain, type) do
    case get(domain, type) do
      %Descriptor{oauth: oauth} -> oauth
      _ -> {:error, :unknown_provider}
    end
  end

  @doc """
  Returns the default provider for a domain.
  """
  @spec default_provider(domain()) :: atom()
  def default_provider(:video),
    do: Tymeslot.Integrations.Video.Providers.ProviderRegistry.default_provider()

  def default_provider(:calendar),
    do: Tymeslot.Integrations.Calendar.Providers.ProviderRegistry.default_provider()

  @doc """
  Validates provider config via provider module.
  """
  @spec validate(domain(), atom(), map()) :: :ok | {:error, any()}
  def validate(domain, type, config) do
    case get(domain, type) do
      %Descriptor{provider_module: mod} when is_atom(mod) and not is_nil(mod) ->
        if function_exported?(mod, :validate_config, 1) do
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(mod, :validate_config, [config])
        else
          :ok
        end

      %Descriptor{provider_module: nil} ->
        :ok

      _ ->
        {:error, :unknown_provider}
    end
  end

  @doc """
  Tests connection for a provider in a domain.
  """
  @spec test_connection(domain(), atom(), map()) :: {:ok, String.t()} | {:error, any()}
  def test_connection(:video, type, config) do
    Tymeslot.Integrations.Video.Providers.ProviderRegistry.test_provider_connection(type, config)
  end

  def test_connection(:calendar, type, config) do
    case Tymeslot.Integrations.Calendar.Providers.ProviderRegistry.get_provider(type) do
      {:ok, mod} ->
        if function_exported?(mod, :test_connection, 1) do
          mod.test_connection(config)
        else
          {:error, :not_supported}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns a setup component module for a provider if one is declared.
  Falls back to nil to use a generic schema-driven form.
  """
  @spec setup_component(domain(), atom()) :: module() | nil | {:error, :unknown_provider}
  def setup_component(domain, type) do
    case get(domain, type) do
      %Descriptor{setup_component: comp} -> comp
      _ -> {:error, :unknown_provider}
    end
  end

  # Internal helpers

  defp domain_provider_types(:video) do
    Tymeslot.Integrations.Video.ProviderConfig.all_providers_with_dev()
  end

  defp domain_provider_types(:calendar) do
    Tymeslot.Integrations.Calendar.ProviderConfig.all_providers_with_dev()
  end

  defp domain_valid_provider?(:video, type) do
    Tymeslot.Integrations.Video.ProviderConfig.valid_provider?(type)
  end

  defp domain_valid_provider?(:calendar, type) do
    Tymeslot.Integrations.Calendar.ProviderConfig.valid_provider?(type)
  end

  defp domain_provider_module(:video, type) do
    Tymeslot.Integrations.Video.ProviderConfig.get_provider_module(type)
  end

  defp domain_provider_module(:calendar, type) do
    Tymeslot.Integrations.Calendar.ProviderConfig.get_provider_module(type)
  end

  defp build_descriptor(domain, type) do
    mod = domain_provider_module(domain, type)

    %Descriptor{
      domain: domain,
      type: type,
      display_name: display_name(domain, type, mod),
      icon: icon_for(type),
      description: nil,
      oauth: oauth_flag(domain, type, mod),
      capabilities: capabilities_for(mod),
      config_schema: schema_for(mod),
      provider_module: mod,
      registry_module: registry_for(domain),
      setup_component: setup_component_for(mod)
    }
  end

  defp display_name(:video, type, mod) do
    if function_exported?(mod, :display_name, 0) do
      mod.display_name()
    else
      Tymeslot.Integrations.Video.ProviderConfig.display_name(type)
    end
  end

  defp display_name(:calendar, type, mod) do
    if function_exported?(mod, :display_name, 0) do
      mod.display_name()
    else
      Tymeslot.Integrations.Calendar.ProviderConfig.display_name(type)
    end
  end

  defp schema_for(mod) do
    if function_exported?(mod, :config_schema, 0) do
      mod.config_schema()
    else
      %{}
    end
  end

  defp capabilities_for(mod) do
    if function_exported?(mod, :capabilities, 0) do
      mod.capabilities()
    else
      %{}
    end
  end

  defp oauth_flag(:video, type, mod) do
    if function_exported?(mod, :oauth?, 0) do
      mod.oauth?()
    else
      type in Tymeslot.Integrations.Video.ProviderConfig.oauth_providers()
    end
  end

  defp oauth_flag(:calendar, type, mod) do
    if function_exported?(mod, :oauth?, 0) do
      mod.oauth?()
    else
      type in Tymeslot.Integrations.Calendar.ProviderConfig.oauth_providers()
    end
  end

  defp setup_component_for(mod) do
    if function_exported?(mod, :setup_component, 0) do
      mod.setup_component()
    else
      nil
    end
  end

  defp registry_for(:video), do: Tymeslot.Integrations.Video.Providers.ProviderRegistry
  defp registry_for(:calendar), do: Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  defp icon_for(type) do
    # Placeholder; can be customized per provider type
    case type do
      :mirotalk -> "hero-video-camera"
      :google_meet -> "hero-video-camera"
      :teams -> "hero-users"
      :custom -> "hero-link"
      _ -> nil
    end
  end
end
