defmodule Tymeslot.Integrations.Providers.Directory do
  @moduledoc """
  Single source of truth for provider metadata and utilities across domains.

  UI and services should query this module to list providers, access their
  config schemas, capabilities, and OAuth support.
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
      _other -> {:error, :unknown_provider}
    end
  end

  @doc """
  Returns capabilities for a provider (may be empty map for calendar).
  """
  @spec capabilities(domain(), atom()) :: map() | {:error, :unknown_provider}
  def capabilities(domain, type) do
    case get(domain, type) do
      %Descriptor{capabilities: caps} -> caps
      _other -> {:error, :unknown_provider}
    end
  end

  @doc """
  Indicates whether a provider uses OAuth.
  """
  @spec oauth?(domain(), atom() | String.t()) :: boolean() | {:error, :unknown_provider}
  def oauth?(domain, type) when domain in [:calendar, :video] do
    case resolve_type(domain, type) do
      nil ->
        {:error, :unknown_provider}

      atom_type ->
        case get(domain, atom_type) do
          %Descriptor{oauth: oauth} -> oauth
          _other -> {:error, :unknown_provider}
        end
    end
  end

  @doc """
  Returns the display name for a provider, with a fallback for unknown providers.
  Accepts provider as atom or string.
  """
  @spec format_provider_name(domain(), atom() | String.t()) :: String.t()
  def format_provider_name(domain, provider) when domain in [:calendar, :video] do
    atom_type = resolve_type(domain, provider)

    case atom_type && get(domain, atom_type) do
      %Descriptor{display_name: name} ->
        name

      _other ->
        provider
        |> to_string()
        |> String.replace("_", " ")
        |> String.capitalize()
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
      %Descriptor{provider_module: mod} when is_atom(mod) and mod != nil ->
        if callback_exported?(mod, :validate_config, 1) do
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(mod, :validate_config, [config])
        else
          :ok
        end

      %Descriptor{provider_module: nil} ->
        :ok

      _other ->
        {:error, :unknown_provider}
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
      _other -> {:error, :unknown_provider}
    end
  end

  # Internal helpers

  # function_exported?/3 returns false for modules that haven't been loaded yet,
  # which would silently fall back to defaults (or skip validation) for a
  # provider whose module simply hasn't been touched in this runtime yet.
  # Force-load first so the check reflects what the module actually exports.
  defp callback_exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

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
    provider_config = domain_provider_config_module(domain)

    %Descriptor{
      domain: domain,
      type: type,
      display_name: display_name(domain, type, mod),
      icon: icon_for(domain, type, provider_config),
      description: description_for(domain, type, provider_config),
      button_text: button_text_for(domain, type, provider_config),
      oauth: oauth_flag(domain, type, mod),
      family: family_for(domain, type, oauth_flag(domain, type, mod)),
      capabilities: capabilities_for(mod),
      config_schema: schema_for(mod),
      provider_module: mod,
      registry_module: registry_for(domain),
      setup_component: setup_component_for(mod)
    }
  end

  defp display_name(:video, type, mod) do
    if callback_exported?(mod, :display_name, 0) do
      mod.display_name()
    else
      Tymeslot.Integrations.Video.ProviderConfig.display_name(type)
    end
  end

  defp display_name(:calendar, type, mod) do
    if callback_exported?(mod, :display_name, 0) do
      mod.display_name()
    else
      Tymeslot.Integrations.Calendar.ProviderConfig.display_name(type)
    end
  end

  defp schema_for(mod) do
    if callback_exported?(mod, :config_schema, 0) do
      mod.config_schema()
    else
      %{}
    end
  end

  defp capabilities_for(mod) do
    if callback_exported?(mod, :capabilities, 0) do
      mod.capabilities()
    else
      %{}
    end
  end

  defp oauth_flag(:video, type, mod) do
    if callback_exported?(mod, :oauth?, 0) do
      mod.oauth?()
    else
      type in Tymeslot.Integrations.Video.ProviderConfig.oauth_providers()
    end
  end

  defp oauth_flag(:calendar, type, mod) do
    if callback_exported?(mod, :oauth?, 0) do
      mod.oauth?()
    else
      type in Tymeslot.Integrations.Calendar.ProviderConfig.oauth_providers()
    end
  end

  defp family_for(_domain, _type, true), do: :oauth

  defp family_for(:calendar, type, _oauth) do
    cond do
      Tymeslot.Integrations.Calendar.ProviderConfig.caldav_based?(type) -> :caldav
      Tymeslot.Integrations.Calendar.ProviderConfig.subscription?(type) -> :subscription
      true -> :other
    end
  end

  defp family_for(:video, _type, _oauth), do: :other

  defp setup_component_for(mod) do
    if callback_exported?(mod, :setup_component, 0) do
      mod.setup_component()
    else
      nil
    end
  end

  defp registry_for(:video), do: Tymeslot.Integrations.Video.Providers.ProviderRegistry
  defp registry_for(:calendar), do: Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  defp domain_provider_config_module(:video), do: Tymeslot.Integrations.Video.ProviderConfig
  defp domain_provider_config_module(:calendar), do: Tymeslot.Integrations.Calendar.ProviderConfig

  defp icon_for(_domain, type, provider_config) do
    provider_config.icon(type)
  end

  defp description_for(_domain, type, provider_config) do
    provider_config.description(type)
  end

  defp button_text_for(_domain, type, provider_config) do
    provider_config.button_text(type)
  end

  @spec resolve_type(domain(), atom() | String.t() | any()) :: atom() | nil
  defp resolve_type(_domain, provider) when is_atom(provider), do: provider

  defp resolve_type(domain, provider) when is_binary(provider) do
    Enum.find(domain_provider_types(domain), fn type ->
      Atom.to_string(type) == provider
    end)
  end

  defp resolve_type(_domain, _provider), do: nil
end
