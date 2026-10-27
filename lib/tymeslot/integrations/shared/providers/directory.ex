defmodule Tymeslot.Integrations.Shared.Providers.Directory do
  @moduledoc """
  Single source of truth for provider metadata and utilities across domains.

  UI and services should query this module to list providers, access their
  config schemas, and OAuth support.
  """

  alias Tymeslot.Integrations.Shared.Providers.Descriptor

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
    family = provider_config.family_of(type)

    %Descriptor{
      domain: domain,
      type: type,
      display_name: display_name(domain, type, mod),
      icon: icon_for(domain, type, provider_config),
      description: description_for(domain, type, provider_config),
      button_text: button_text_for(domain, type, provider_config),
      # OAuth-ness is not a second fact about a provider: it is membership of
      # the `:oauth` family, read from the same table as the family itself so
      # the two cannot disagree.
      oauth: family == :oauth,
      family: family,
      config_schema: schema_for(mod),
      provider_module: mod,
      registry_module: registry_for(domain),
      setup_component: setup_component_for(mod)
    }
  end

  # Video providers' names live in their configuration table alone.
  defp display_name(:video, type, _mod),
    do: Tymeslot.Integrations.Video.ProviderConfig.display_name(type)

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

  defp setup_component_for(mod) do
    if callback_exported?(mod, :setup_component, 0) do
      mod.setup_component()
    else
      nil
    end
  end

  defp registry_for(:video), do: Tymeslot.Integrations.Video.ProviderConfig
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
