defmodule Tymeslot.Integrations.Calendar.ProviderConfig do
  @moduledoc """
  Centralized configuration for calendar providers.

  This module serves as the single source of truth for provider types,
  classifications, and validation across the calendar integration system.
  Supports enabling/disabling providers via config (config.exs).
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Shared.{ProviderConfigHelper, ProviderToggle}

  @providers [:caldav, :radicale, :nextcloud, :google, :outlook, :demo]
  @oauth_providers [:google, :outlook]
  @caldav_based_providers [:caldav, :radicale, :nextcloud]
  @dev_only_providers [:debug]

  # Read provider settings from config
  @doc false
  @spec provider_settings() :: map()
  def provider_settings do
    Config.calendar_provider_settings()
  end

  @doc false
  @spec provider_enabled?(atom()) :: boolean()
  def provider_enabled?(type) when is_atom(type) do
    ProviderToggle.enabled?(provider_settings(), type, default_enabled: false)
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
  Returns all production calendar providers (enabled only).
  """
  @spec all_providers() :: list(atom())
  def all_providers, do: effective_providers(false)

  @doc """
  Returns all providers including development-only ones (enabled only).
  """
  @spec all_providers_with_dev() :: list(atom())
  def all_providers_with_dev do
    effective_providers(true)
  end

  @doc """
  Returns OAuth-based providers.
  """
  @spec oauth_providers() :: list(atom())
  def oauth_providers, do: @oauth_providers

  @doc """
  Returns CalDAV-based providers.
  """
  @spec caldav_based_providers() :: list(atom())
  def caldav_based_providers, do: @caldav_based_providers

  @doc """
  Checks if a provider is valid.
  """
  @spec valid_provider?(atom()) :: boolean()
  def valid_provider?(provider) when is_atom(provider) do
    provider in all_providers_with_dev()
  end

  def valid_provider?(_), do: false

  @doc """
  Checks if a provider is OAuth-based.
  """
  @spec oauth_provider?(atom()) :: boolean()
  def oauth_provider?(provider) when is_atom(provider) do
    provider in @oauth_providers
  end

  def oauth_provider?(_), do: false

  @doc """
  Checks if a provider is CalDAV-based.
  """
  @spec caldav_based?(atom()) :: boolean()
  def caldav_based?(provider) when is_atom(provider) do
    provider in @caldav_based_providers
  end

  def caldav_based?(_), do: false

  @doc """
  Validates and normalizes a provider type.

  Returns {:ok, provider} if valid, {:error, reason} otherwise.
  """
  @spec validate_provider(atom() | String.t()) :: {:ok, atom()} | {:error, String.t()}
  def validate_provider(provider) when is_binary(provider) do
    validate_provider(String.to_existing_atom(provider))
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
  def display_name(:caldav), do: "CalDAV"
  def display_name(:radicale), do: "Radicale"
  def display_name(:nextcloud), do: "Nextcloud"
  def display_name(:google), do: "Google Calendar"
  def display_name(:outlook), do: "Outlook Calendar"
  def display_name(:debug), do: "Debug Provider"
  def display_name(:demo), do: "Demo Provider"
  def display_name(_), do: "Unknown Provider"

  @doc """
  Gets the provider module for a given provider type.
  """
  @spec get_provider_module(atom()) :: module() | nil
  def get_provider_module(:caldav), do: Tymeslot.Integrations.Calendar.CalDAV.Provider
  def get_provider_module(:radicale), do: Tymeslot.Integrations.Calendar.Radicale.Provider
  def get_provider_module(:nextcloud), do: Tymeslot.Integrations.Calendar.Nextcloud.Provider
  def get_provider_module(:google), do: Tymeslot.Integrations.Calendar.Google.Provider
  def get_provider_module(:outlook), do: Tymeslot.Integrations.Calendar.Outlook.Provider
  def get_provider_module(:debug), do: Tymeslot.Integrations.Calendar.DebugCalendarProvider
  def get_provider_module(:demo), do: Tymeslot.Integrations.Calendar.DemoCalendarProvider
  def get_provider_module(_), do: nil

  @doc """
  Returns provider string for database constraint.
  Used in migrations and changesets.
  """
  @spec provider_constraint_list() :: list(String.t())
  def provider_constraint_list do
    # DB constraints should allow all supported providers, regardless of runtime enable/disable
    # toggles, so existing integrations don't become invalid when a provider is temporarily off.
    (@providers ++ @dev_only_providers)
    |> Enum.uniq()
    |> Enum.map(&Atom.to_string/1)
  end

  # Private helpers

  defp format_invalid_provider_error(provider) do
    valid_list = Enum.join(all_providers_with_dev(), ", ")
    "Invalid provider: #{inspect(provider)}. Valid providers are: #{valid_list}"
  end
end
