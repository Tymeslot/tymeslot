defmodule Tymeslot.Integrations.Video.ProviderConfig do
  @moduledoc """
  Centralized configuration for video providers.

  This module serves as the single source of truth for provider types,
  classifications, display names, and validation across the video integration system.
  It supports enabling/disabling providers via config (config.exs).
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Shared.{ProviderConfigHelper, ProviderToggle}

  @providers [:mirotalk, :google_meet, :teams, :custom]
  @oauth_providers [:google_meet, :teams]
  @dev_only_providers []

  # Read provider settings from config
  @doc false
  @spec provider_settings() :: map()
  def provider_settings do
    Config.video_provider_settings()
  end

  @doc false
  @spec provider_enabled?(atom()) :: boolean()
  def provider_enabled?(type) when is_atom(type) do
    ProviderToggle.enabled?(provider_settings(), type, default_enabled: true)
  end

  defp effective_providers(include_dev) do
    ProviderConfigHelper.effective_providers(
      @providers,
      @dev_only_providers,
      include_dev,
      &provider_enabled?/1
    )
  end

  @doc """
  Returns all production video providers (enabled only).
  """
  @spec all_providers() :: list(atom())
  def all_providers, do: effective_providers(false)

  @doc """
  Returns all providers including development-only (enabled only).
  """
  @spec all_providers_with_dev() :: list(atom())
  def all_providers_with_dev, do: effective_providers(true)

  @doc """
  Returns OAuth-based providers.
  """
  @spec oauth_providers() :: list(atom())
  def oauth_providers, do: @oauth_providers

  @doc """
  Checks if a provider is valid.
  """
  @spec valid_provider?(atom()) :: boolean()
  def valid_provider?(provider) when is_atom(provider) do
    provider in all_providers_with_dev()
  end

  def valid_provider?(_), do: false

  @doc """
  Validates and normalizes a provider type.

  Returns {:ok, provider} if valid, {:error, reason} otherwise.
  """
  @spec validate_provider(atom() | String.t()) :: {:ok, atom()} | {:error, String.t()}
  def validate_provider(provider) when is_binary(provider) do
    provider
    |> String.to_existing_atom()
    |> validate_provider()
  rescue
    ArgumentError ->
      {:error, format_invalid_provider_error(provider)}
  end

  def validate_provider(provider) when is_atom(provider) do
    if valid_provider?(provider) do
      {:ok, provider}
    else
      {:error, format_invalid_provider_error(provider)}
    end
  end

  def validate_provider(provider) do
    {:error, format_invalid_provider_error(provider)}
  end

  @doc """
  Gets the display name for a provider.
  """
  @spec display_name(atom()) :: String.t()
  def display_name(:mirotalk), do: "MiroTalk P2P"
  def display_name(:google_meet), do: "Google Meet"
  def display_name(:teams), do: "Microsoft Teams"
  def display_name(:custom), do: "Custom Video Link"
  def display_name(_), do: "Unknown Provider"

  @doc """
  Returns the provider modules list (enabled only).

  Used to compute the providers map for registries.
  """
  @spec provider_modules() :: [module()]
  def provider_modules do
    all_providers_with_dev()
    |> Enum.map(&get_provider_module/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Gets the provider module for a given provider type.
  """
  @spec get_provider_module(atom()) :: module() | nil
  def get_provider_module(:mirotalk), do: Tymeslot.Integrations.Video.Providers.MiroTalkProvider

  def get_provider_module(:google_meet),
    do: Tymeslot.Integrations.Video.Providers.GoogleMeetProvider

  def get_provider_module(:teams), do: Tymeslot.Integrations.Video.Providers.TeamsProvider
  def get_provider_module(:custom), do: Tymeslot.Integrations.Video.Providers.CustomProvider
  def get_provider_module(_), do: nil

  @doc """
  Returns a providers map suitable for the registry (type => module) for enabled providers.
  """
  @spec providers_map() :: %{atom() => module()}
  def providers_map do
    all_providers_with_dev()
    |> Enum.map(fn type -> {type, get_provider_module(type)} end)
    |> Enum.reject(fn {_type, mod} -> is_nil(mod) end)
    |> Map.new()
  end

  @doc """
  Returns provider strings for database constraint validation.
  """
  @spec provider_constraint_list() :: list(String.t())
  def provider_constraint_list do
    Enum.map(all_providers_with_dev(), &Atom.to_string/1)
  end

  # Private helpers
  defp format_invalid_provider_error(provider) do
    valid_list = Enum.join(all_providers_with_dev(), ", ")
    "Invalid provider: #{inspect(provider)}. Valid providers are: #{valid_list}"
  end
end
