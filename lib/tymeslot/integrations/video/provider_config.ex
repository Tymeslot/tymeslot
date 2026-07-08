defmodule Tymeslot.Integrations.Video.ProviderConfig do
  @moduledoc """
  Centralized configuration for video providers.

  This module serves as the single source of truth for provider types,
  classifications, display names, and validation across the video integration system.
  It supports enabling/disabling providers via config (config.exs).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Shared.{ProviderConfigHelper, ProviderToggle}

  @providers [:mirotalk, :google_meet, :teams, :zoom, :custom]
  @oauth_providers [:google_meet, :teams, :zoom]
  @dev_only_providers []

  # Provider metadata - single source of truth for all provider information
  @provider_metadata %{
    mirotalk: %{
      icon: "mirotalk",
      description:
        dgettext_noop("dashboard_integrations", "Self-hosted peer-to-peer video meetings"),
      button_text: "Connect MiroTalk",
      click_event: "connect_mirotalk",
      circuit_breaker_enabled: true
    },
    google_meet: %{
      icon: "google_meet",
      description:
        dgettext_noop(
          "dashboard_integrations",
          "Full OAuth integration with automatic room creation"
        ),
      button_text: "Connect Google Meet",
      click_event: "connect_google_meet",
      circuit_breaker_enabled: true
    },
    teams: %{
      icon: "teams",
      description:
        dgettext_noop(
          "dashboard_integrations",
          "Enterprise OAuth integration with organizational accounts"
        ),
      button_text: "Connect Teams",
      click_event: "connect_teams",
      circuit_breaker_enabled: true
    },
    zoom: %{
      icon: "zoom",
      description:
        dgettext_noop(
          "dashboard_integrations",
          "OAuth integration with automatic Zoom meeting creation"
        ),
      button_text: "Connect Zoom",
      click_event: "connect_zoom",
      circuit_breaker_enabled: true
    },
    custom: %{
      icon: "custom",
      description:
        dgettext_noop("dashboard_integrations", "Any video platform with static meeting URLs"),
      button_text: "Add Custom Link",
      click_event: "connect_custom",
      circuit_breaker_enabled: false
    }
  }

  # Read provider settings from config
  @doc false
  @spec provider_settings() :: %{atom() => term()}
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

  def valid_provider?(_provider), do: false

  @doc """
  Gets full metadata for a provider.

  Returns a map with icon, description, button_text, click_event, and circuit_breaker_enabled fields.
  """
  @spec metadata(atom()) :: %{
          required(:icon) => String.t(),
          required(:description) => String.t(),
          required(:button_text) => String.t(),
          required(:click_event) => String.t() | nil,
          required(:circuit_breaker_enabled) => boolean()
        }
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
  def description(provider) do
    Gettext.dgettext(
      TymeslotWeb.Gettext,
      "dashboard_integrations",
      metadata(provider).description
    )
  end

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
  Parses a provider identifier (atom or string) to its canonical atom form.

  Accepts the providers in `@providers` plus the meta-value `:none`
  (used as a sentinel for "video disabled" on an integration record).
  Returns `{:error, :unknown}` for anything else — including unrelated
  atoms the system happens to know about. This is the canonical
  string↔atom converter; do not reimplement.

  This variant is **toggle-aware**: it only accepts providers that are
  currently enabled. Use it to gate new OAuth/setup flows. For operations
  on persisted integrations (where the provider may have been disabled after
  the integration was created), use `parse_known/1` instead.
  """
  @spec parse(atom() | String.t() | any()) :: {:ok, atom()} | {:error, :unknown}
  def parse(:none), do: {:ok, :none}

  def parse(provider) when is_atom(provider) do
    if valid_provider?(provider), do: {:ok, provider}, else: {:error, :unknown}
  end

  def parse("none"), do: {:ok, :none}

  def parse(provider) when is_binary(provider) do
    parse(String.to_existing_atom(provider))
  rescue
    ArgumentError -> {:error, :unknown}
  end

  def parse(_other), do: {:error, :unknown}

  @doc """
  Toggle-agnostic counterpart to `parse/1`.

  Parses a provider identifier against the full static `@providers` list,
  regardless of whether that provider is currently enabled via config.
  Use this for any operation on a persisted integration — connection tests,
  credential validation, room creation — where the provider may have been
  disabled after the integration was created.

  Returns `{:ok, provider_atom}` for any known provider (or `:none`),
  `{:error, :unknown}` for anything not in `@providers`.
  """
  @spec parse_known(atom() | String.t() | any()) :: {:ok, atom()} | {:error, :unknown}
  def parse_known(:none), do: {:ok, :none}

  def parse_known(provider) when is_atom(provider) do
    if provider in @providers, do: {:ok, provider}, else: {:error, :unknown}
  end

  def parse_known("none"), do: {:ok, :none}

  def parse_known(provider) when is_binary(provider) do
    parse_known(String.to_existing_atom(provider))
  rescue
    ArgumentError -> {:error, :unknown}
  end

  def parse_known(_other), do: {:error, :unknown}

  @doc """
  Checks whether a provider uses OAuth for setup/reconnect.
  Accepts atom or string.
  """
  @spec oauth_provider?(atom() | String.t() | any()) :: boolean()
  def oauth_provider?(provider) do
    case parse(provider) do
      {:ok, atom} -> atom in @oauth_providers
      {:error, :unknown} -> false
    end
  end

  @display_names %{
    mirotalk: "MiroTalk P2P",
    google_meet: "Google Meet",
    teams: "Microsoft Teams",
    zoom: "Zoom",
    custom: "Custom Video Link"
  }

  @doc """
  Gets the display name for a provider.
  """
  @spec display_name(atom()) :: String.t()
  def display_name(provider), do: Map.get(@display_names, provider, "Unknown Provider")

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
  def get_provider_module(:zoom), do: Tymeslot.Integrations.Video.Providers.ZoomProvider
  def get_provider_module(:custom), do: Tymeslot.Integrations.Video.Providers.CustomProvider
  def get_provider_module(_provider), do: nil

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
  Returns provider strings for database constraint validation (enabled providers only).
  """
  @spec provider_constraint_list() :: list(String.t())
  def provider_constraint_list do
    Enum.map(all_providers_with_dev(), &Atom.to_string/1)
  end

  @doc """
  Returns provider strings for changeset inclusion validation on persisted rows.

  Unlike `provider_constraint_list/0` this is toggle-agnostic: it always
  returns all providers in `@providers`, ensuring that existing DB rows for
  a now-disabled provider still pass changeset validation.
  """
  @spec provider_constraint_list_all() :: list(String.t())
  def provider_constraint_list_all do
    Enum.map(@providers, &Atom.to_string/1)
  end

  # Private helpers
  defp format_invalid_provider_error(provider) do
    valid_list = Enum.join(all_providers_with_dev(), ", ")
    "Invalid provider: #{inspect(provider)}. Valid providers are: #{valid_list}"
  end
end
