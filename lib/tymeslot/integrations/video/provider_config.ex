defmodule Tymeslot.Integrations.Video.ProviderConfig do
  @moduledoc """
  Centralized configuration for video providers.

  This module serves as the single source of truth for provider types,
  classifications, display names, and validation across the video integration system.
  It supports enabling/disabling providers via config (config.exs).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Providers.Families
  alias Tymeslot.Integrations.Shared.{ProviderConfigHelper, ProviderToggle}

  @providers [:mirotalk, :google_meet, :teams, :zoom, :custom]
  @dev_only_providers []

  # The single declaration site for "how does this provider connect?", in the
  # shared vocabulary of `Tymeslot.Integrations.Providers.Families`. Video has
  # no CalDAV or subscription providers, so those families are simply empty
  # here; a provider missing from this table fails the build.
  @provider_families %{
    oauth: [:google_meet, :teams, :zoom],
    other: [:mirotalk, :custom]
  }

  # Keyed by both the atom and the string form of every provider, so the two
  # forms of the same provider cannot get different answers out of the
  # predicates below.
  @family_index Families.build_index(@provider_families, @providers ++ @dev_only_providers)

  @oauth_providers Families.members(@provider_families, :oauth)

  # Compile-time lookup from the provider's string form to its atom, covering
  # every statically known provider regardless of runtime toggles. Parsing
  # through this table keeps the string entry points total: no
  # `String.to_existing_atom/1` raise to rescue, and no dependence on whether
  # the atom happens to have been loaded yet.
  @provider_atoms Map.new(@providers ++ @dev_only_providers, &{Atom.to_string(&1), &1})

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
    case Map.fetch(@provider_atoms, provider) do
      {:ok, atom} -> validate_provider(atom)
      :error -> {:error, format_invalid_provider_error(provider)}
    end
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
    case Map.fetch(@provider_atoms, provider) do
      {:ok, atom} -> parse(atom)
      :error -> {:error, :unknown}
    end
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
    case Map.fetch(@provider_atoms, provider) do
      {:ok, atom} -> parse_known(atom)
      :error -> {:error, :unknown}
    end
  end

  def parse_known(_other), do: {:error, :unknown}

  @doc """
  Returns the family a provider belongs to.

  Accepts the atom or the string form and answers identically for both: the
  database column and LiveView params carry the string. Anything the table
  does not know — including the `:none` sentinel — is `:other`.

  Deliberately toggle-agnostic: a persisted Zoom integration is an OAuth
  integration whether or not Zoom is currently switched on in config, and the
  reconnect UI has to keep saying so.
  """
  @spec family_of(atom() | String.t() | any()) :: Families.t()
  def family_of(provider), do: Families.of(@family_index, provider)

  @doc """
  Checks whether a provider belongs to `family`. Accepts atom or string.
  """
  @spec in_family?(atom() | String.t() | any(), Families.t()) :: boolean()
  def in_family?(provider, family), do: family_of(provider) == family

  @doc """
  Checks whether a provider uses OAuth for setup/reconnect.
  Accepts atom or string.
  """
  @spec oauth_provider?(atom() | String.t() | any()) :: boolean()
  def oauth_provider?(provider), do: in_family?(provider, :oauth)

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
  Returns provider strings for changeset inclusion validation on persisted rows.

  This is toggle-agnostic: it always returns all providers in `@providers`,
  ensuring that existing DB rows for a now-disabled provider still pass
  changeset validation.
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
