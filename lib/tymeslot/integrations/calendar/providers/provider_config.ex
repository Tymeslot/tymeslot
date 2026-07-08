defmodule Tymeslot.Integrations.Calendar.ProviderConfig do
  @moduledoc """
  Centralized configuration for calendar providers.

  This module serves as the single source of truth for provider types,
  classifications, and validation across the calendar integration system.
  Supports enabling/disabling providers via config (config.exs); providers
  listed in `@providers` are enabled by default unless explicitly turned off.

  ## Internal providers

  `:demo` (fake availability for the public homepage demo) and `:debug`
  (dev/test pipeline debugging) are not user-connectable but live in this
  module so the registry, schema validation, and DB constraint list still
  recognise them. Because the runtime toggle defaults to enabled, each is
  pinned off via `config :tymeslot, :calendar_providers` in all three
  config sites — `apps/tymeslot/config/config.exs`,
  `apps/tymeslot/config/test.exs`, and `config/test.exs` — otherwise they
  surface as cards in the calendars tab of the integrations hub
  (`/dashboard/integrations?tab=calendars`). Add
  `<name>: [enabled: false]` to the same three blocks when introducing
  any further internal-only provider.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Shared.{ProviderConfigHelper, ProviderToggle}

  # How far back and forward sync workers fetch events from providers.
  # Shared across all providers so the dashboard calendar shows a consistent range.
  @sync_window_past_days 365
  @sync_window_future_days 365

  @providers [
    :caldav,
    :radicale,
    :nextcloud,
    :zimbra,
    :mailbox_org,
    :apple,
    :baikal,
    :google,
    :outlook,
    :demo
  ]
  @oauth_providers [:google, :outlook]
  @caldav_based_providers [:caldav, :radicale, :nextcloud, :zimbra, :mailbox_org, :apple, :baikal]
  @dev_only_providers [:debug]

  # Providers whose CalDAV server URL is fixed and must never be edited by the
  # user — both during initial connection and reconnection. A provider absent
  # from this map allows the user to enter their own server URL.
  @locked_url_providers %{
    mailbox_org: %{
      url: "https://dav.mailbox.org",
      tooltip: "mailbox.org always uses this CalDAV server — the address cannot be changed"
    },
    apple: %{
      url: "https://caldav.icloud.com",
      tooltip: "Apple iCloud always uses this CalDAV server — the address cannot be changed"
    }
  }

  @locked_url_providers_by_string Map.new(@locked_url_providers, fn {atom_key, value} ->
                                    {Atom.to_string(atom_key), value}
                                  end)

  # Provider metadata - single source of truth for all provider information
  @provider_metadata %{
    caldav: %{
      icon: "caldav",
      description:
        dgettext_noop("dashboard_calendar_providers", "Universal CalDAV server support"),
      button_text: "Connect CalDAV",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    radicale: %{
      icon: "radicale",
      description:
        dgettext_noop("dashboard_calendar_providers", "Lightweight self-hosted calendar server"),
      button_text: "Connect Radicale",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    nextcloud: %{
      icon: "nextcloud",
      description:
        dgettext_noop("dashboard_calendar_providers", "Self-hosted Nextcloud calendar sync"),
      button_text: "Connect Nextcloud",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    zimbra: %{
      icon: "zimbra",
      description:
        dgettext_noop("dashboard_calendar_providers", "Enterprise Zimbra calendar integration"),
      button_text: "Connect Zimbra",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    mailbox_org: %{
      icon: "mailbox_org",
      description:
        dgettext_noop(
          "dashboard_calendar_providers",
          "Sync calendars from your mailbox.org account"
        ),
      button_text: "Connect mailbox.org",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    apple: %{
      icon: "apple",
      description:
        dgettext_noop(
          "dashboard_calendar_providers",
          "Sync calendars from your Apple iCloud account"
        ),
      button_text: "Connect Apple iCloud",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    baikal: %{
      icon: "baikal",
      description:
        dgettext_noop(
          "dashboard_calendar_providers",
          "PHP-based CalDAV/CardDAV server integration"
        ),
      button_text: "Connect Baikal",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    google: %{
      icon: "google",
      description:
        dgettext_noop(
          "dashboard_calendar_providers",
          "Full OAuth integration with Google Meet support"
        ),
      button_text: "Connect Google",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    outlook: %{
      icon: "outlook",
      description:
        dgettext_noop("dashboard_calendar_providers", "Microsoft 365 and Outlook.com integration"),
      button_text: "Connect Outlook",
      click_event: "connect_provider",
      circuit_breaker_enabled: true
    },
    demo: %{
      icon: "demo",
      description: dgettext_noop("dashboard_calendar_providers", "Homepage demo provider"),
      button_text: "Demo Enabled",
      click_event: nil,
      circuit_breaker_enabled: false
    }
  }

  # Read provider settings from config
  @doc false
  @spec provider_settings() :: %{atom() => term()}
  def provider_settings do
    Config.calendar_provider_settings()
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

  @caldav_based_provider_strings Enum.map(@caldav_based_providers, &Atom.to_string/1)

  @doc """
  Returns CalDAV-based providers as strings, for matching against database
  string values such as `integration.provider`.
  """
  @spec caldav_based_provider_strings() :: list(String.t())
  def caldav_based_provider_strings, do: @caldav_based_provider_strings

  # Order follows @providers — the canonical provider list — for deterministic results.
  @providers_with_circuit_breakers for p <- @providers,
                                       get_in(@provider_metadata, [p, :circuit_breaker_enabled]),
                                       do: p

  @doc """
  Returns providers that have circuit-breaker monitoring enabled.

  Ordered to match `@providers`. Includes both CalDAV-based and OAuth providers;
  excludes providers whose metadata sets `circuit_breaker_enabled: false`.
  """
  @spec providers_with_circuit_breakers() :: list(atom())
  def providers_with_circuit_breakers, do: @providers_with_circuit_breakers

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
  Returns the fixed CalDAV server URL for a provider, or `nil` if the user
  is free to choose their own.

  Used by both connect and reconnect UIs to render a locked, greyed-out URL
  field for providers like mailbox.org whose server address is invariant.
  Accepts atom or string provider identifiers (database values are strings).
  """
  @spec locked_url_for(atom() | String.t()) ::
          %{url: String.t(), tooltip: String.t()} | nil
  def locked_url_for(provider) when is_atom(provider),
    do: Map.get(@locked_url_providers, provider)

  def locked_url_for(provider) when is_binary(provider),
    do: Map.get(@locked_url_providers_by_string, provider)

  def locked_url_for(_provider), do: nil

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
      "dashboard_calendar_providers",
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
  Parses a provider identifier (atom or string) to its canonical atom form.

  This variant is **toggle-aware**: it only accepts providers that are
  currently enabled via config. Use it to gate new setup or connection
  flows. For operations on persisted integrations (where the provider may
  have been disabled after the integration was created), use
  `parse_known/1` instead.

  Returns `{:ok, provider_atom}` for enabled providers,
  `{:error, :unknown}` for anything else.
  """
  @spec parse(atom() | String.t() | any()) :: {:ok, atom()} | {:error, :unknown}
  def parse(provider) when is_atom(provider) do
    if valid_provider?(provider), do: {:ok, provider}, else: {:error, :unknown}
  end

  def parse(provider) when is_binary(provider) do
    parse(String.to_existing_atom(provider))
  rescue
    ArgumentError -> {:error, :unknown}
  end

  def parse(_other), do: {:error, :unknown}

  @doc """
  Toggle-agnostic counterpart to `parse/1`.

  Parses a provider identifier against the full static provider list
  (`@providers` plus `@dev_only_providers`), regardless of whether that
  provider is currently enabled via config. Use this for any operation
  on a persisted integration — connection tests, client construction,
  sync, room creation — where the provider may have been disabled after
  the integration was created.

  Returns `{:ok, provider_atom}` for any known provider,
  `{:error, :unknown}` for anything not in the static list.
  """
  @spec parse_known(atom() | String.t() | any()) :: {:ok, atom()} | {:error, :unknown}
  def parse_known(provider) when is_atom(provider) do
    if provider in @providers or provider in @dev_only_providers do
      {:ok, provider}
    else
      {:error, :unknown}
    end
  end

  def parse_known(provider) when is_binary(provider) do
    parse_known(String.to_existing_atom(provider))
  rescue
    ArgumentError -> {:error, :unknown}
  end

  def parse_known(_other), do: {:error, :unknown}

  @doc """
  Gets the display name for a provider.
  """
  @spec display_name(atom()) :: String.t()
  def display_name(:caldav), do: "CalDAV"
  def display_name(:radicale), do: "Radicale"
  def display_name(:nextcloud), do: "Nextcloud"
  def display_name(:zimbra), do: "Zimbra"
  def display_name(:mailbox_org), do: "mailbox.org"
  def display_name(:apple), do: "Apple iCloud"
  def display_name(:baikal), do: "Baikal"
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

  def get_provider_module(:mailbox_org),
    do: Tymeslot.Integrations.Calendar.MailboxOrg.Provider

  def get_provider_module(:apple), do: Tymeslot.Integrations.Calendar.Apple.Provider

  def get_provider_module(:baikal), do: Tymeslot.Integrations.Calendar.Baikal.Provider

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
