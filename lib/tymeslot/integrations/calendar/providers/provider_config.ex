defmodule Tymeslot.Integrations.Calendar.ProviderConfig do
  @moduledoc """
  Centralized configuration for calendar providers.

  This module serves as the single source of truth for provider types,
  classifications, and validation across the calendar integration system.
  Supports enabling/disabling providers via config (config.exs).
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Shared.{ProviderConfigHelper, ProviderToggle}

  # How far back and forward sync workers fetch events from providers.
  # Shared across all providers so the dashboard calendar shows a consistent range.
  @sync_window_past_days 365
  @sync_window_future_days 365

  @providers [:caldav, :radicale, :nextcloud, :zimbra, :google, :outlook, :demo]
  @oauth_providers [:google, :outlook]
  @caldav_based_providers [:caldav, :radicale, :nextcloud, :zimbra]
  @dev_only_providers [:debug]

  # Provider metadata - single source of truth for all provider information
  @provider_metadata %{
    caldav: %{
      icon: "caldav",
      description: "Universal CalDAV server support",
      button_text: "Connect CalDAV",
      click_event: "connect_caldav_calendar",
      circuit_breaker_enabled: true
    },
    radicale: %{
      icon: "radicale",
      description: "Lightweight self-hosted calendar server",
      button_text: "Connect Radicale",
      click_event: "connect_radicale_calendar",
      circuit_breaker_enabled: true
    },
    nextcloud: %{
      icon: "nextcloud",
      description: "Self-hosted Nextcloud calendar sync",
      button_text: "Connect Nextcloud",
      click_event: "connect_nextcloud_calendar",
      circuit_breaker_enabled: true
    },
    zimbra: %{
      icon: "zimbra",
      description: "Enterprise Zimbra calendar integration",
      button_text: "Connect Zimbra",
      click_event: "connect_zimbra_calendar",
      circuit_breaker_enabled: true
    },
    google: %{
      icon: "google",
      description: "Full OAuth integration with Google Meet support",
      button_text: "Connect Google",
      click_event: "connect_google_calendar",
      circuit_breaker_enabled: true
    },
    outlook: %{
      icon: "outlook",
      description: "Microsoft 365 and Outlook.com integration",
      button_text: "Connect Outlook",
      click_event: "connect_outlook_calendar",
      circuit_breaker_enabled: true
    },
    demo: %{
      icon: "demo",
      description: "Homepage demo provider",
      button_text: "Demo Enabled",
      click_event: nil,
      circuit_breaker_enabled: false
    }
  }

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

  @doc "Number of days in the past to fetch events during sync."
  @spec sync_window_past_days() :: pos_integer()
  def sync_window_past_days, do: @sync_window_past_days

  @doc "Number of days in the future to fetch events during sync."
  @spec sync_window_future_days() :: pos_integer()
  def sync_window_future_days, do: @sync_window_future_days

  @doc """
  Checks if a provider is valid.
  """
  @spec valid_provider?(atom()) :: boolean()
  def valid_provider?(provider) when is_atom(provider) do
    provider in all_providers_with_dev()
  end

  def valid_provider?(_provider), do: false

  @doc """
  Checks if a provider is OAuth-based.
  """
  @spec oauth_provider?(atom()) :: boolean()
  def oauth_provider?(provider) when is_atom(provider) do
    provider in @oauth_providers
  end

  def oauth_provider?(_provider), do: false

  @doc """
  Checks if a provider is CalDAV-based.
  """
  @spec caldav_based?(atom()) :: boolean()
  def caldav_based?(provider) when is_atom(provider) do
    provider in @caldav_based_providers
  end

  def caldav_based?(_provider), do: false

  @doc """
  Gets full metadata for a provider.

  Returns a map with icon, description, button_text, click_event, and circuit_breaker_enabled fields.
  """
  @spec metadata(atom()) :: map()
  def metadata(provider) when is_atom(provider) do
    Map.get(@provider_metadata, provider, %{
      icon: Atom.to_string(provider),
      description: "",
      button_text: "Connect",
      click_event: nil,
      circuit_breaker_enabled: false
    })
  end

  @doc """
  Gets icon identifier for a provider.
  """
  @spec icon(atom()) :: String.t()
  def icon(provider), do: metadata(provider).icon

  @doc """
  Gets description for a provider.
  """
  @spec description(atom()) :: String.t()
  def description(provider), do: metadata(provider).description

  @doc """
  Gets button text for a provider.
  """
  @spec button_text(atom()) :: String.t()
  def button_text(provider), do: metadata(provider).button_text

  @doc """
  Gets click event name for a provider.
  """
  @spec click_event(atom()) :: String.t() | nil
  def click_event(provider), do: metadata(provider).click_event

  @doc """
  Checks if provider requires circuit breaker monitoring.
  """
  @spec circuit_breaker_enabled?(atom()) :: boolean()
  def circuit_breaker_enabled?(provider), do: metadata(provider).circuit_breaker_enabled

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
  def display_name(:zimbra), do: "Zimbra"
  def display_name(:google), do: "Google Calendar"
  def display_name(:outlook), do: "Outlook Calendar"
  def display_name(:debug), do: "Debug Provider"
  def display_name(:demo), do: "Demo Provider"
  def display_name(_provider), do: "Unknown Provider"

  @doc """
  Gets the provider module for a given provider type.
  """
  @spec get_provider_module(atom()) :: module() | nil
  def get_provider_module(:caldav), do: Tymeslot.Integrations.Calendar.CalDAV.Provider
  def get_provider_module(:radicale), do: Tymeslot.Integrations.Calendar.Radicale.Provider
  def get_provider_module(:nextcloud), do: Tymeslot.Integrations.Calendar.Nextcloud.Provider
  def get_provider_module(:zimbra), do: Tymeslot.Integrations.Calendar.Zimbra.Provider
  def get_provider_module(:google), do: Tymeslot.Integrations.Calendar.Google.Provider
  def get_provider_module(:outlook), do: Tymeslot.Integrations.Calendar.Outlook.Provider
  def get_provider_module(:debug), do: Tymeslot.Integrations.Calendar.DebugCalendarProvider
  def get_provider_module(:demo), do: Tymeslot.Integrations.Calendar.DemoCalendarProvider
  def get_provider_module(_provider), do: nil

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
