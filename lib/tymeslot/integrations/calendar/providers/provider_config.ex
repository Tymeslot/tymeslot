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
  pinned off via `config :tymeslot, :calendar_providers` in both config
  sites, `config/config.exs` and `config/test.exs`; otherwise they surface
  as cards in the calendars tab of the integrations hub
  (`/dashboard/integrations?tab=calendars`). Add `<name>: [enabled: false]`
  to both blocks when introducing any further internal-only provider, and
  to the equivalent block in any downstream overlay that redefines the map.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalDAV.Family
  alias Tymeslot.Integrations.Calendar.ProviderConfig.Metadata
  alias Tymeslot.Integrations.Shared.{ProviderConfigHelper, ProviderToggle}
  alias Tymeslot.Integrations.Shared.Providers.Families

  @providers [
    :caldav,
    :radicale,
    :nextcloud,
    :zimbra,
    :mailbox_org,
    :apple,
    :baikal,
    :ics_url,
    :google,
    :outlook,
    :exchange,
    :demo
  ]
  @dev_only_providers [:debug]

  # The single declaration site for "how does this provider connect?". Every
  # provider list, string list and family predicate below derives from this
  # table, and `Families.build_index/2` fails the build if a provider in
  # `@providers` is missing from it, filed twice, or filed under a family
  # outside the shared vocabulary — so adding a provider, or a family, is one
  # edit here.
  #
  # EWS providers speak SOAP over HTTPS with credentials. They are deliberately
  # not CalDAV — no PROPFIND discovery, no href/etag model — and not OAuth,
  # because on-premises Exchange authenticates with Windows credentials rather
  # than a token endpoint. Filing one under `:caldav` would have
  # `ProviderAdapter` and `CaldavCommon` build a CalDAV client for a SOAP
  # provider.
  #
  # Subscription providers subscribe to a published feed rather than talking a
  # calendar protocol. They are deliberately *not* CalDAV-family: they carry
  # no credentials, discover nothing, and can never be written to, so every
  # "is this CalDAV?" branch must answer no for them rather than yes with a
  # carve-out.
  #
  # The internal providers (see the moduledoc) connect by no mechanism a user
  # can pick, so they are filed under `:other` rather than left out.
  @provider_families %{
    oauth: [:google, :outlook],
    caldav: Family.members(),
    ews: [:exchange],
    subscription: [:ics_url],
    other: [:demo, :debug]
  }

  # Keyed by both the atom and the string form of every provider, so the two
  # forms of the same provider cannot get different answers out of the
  # predicates below.
  @family_index Families.build_index(@provider_families, @providers ++ @dev_only_providers)

  # Providers whose module refuses every write. See `read_only?/1`.
  @read_only_providers [:ics_url]
  @read_only_provider_strings Enum.map(@read_only_providers, &Atom.to_string/1)

  @caldav_based_providers Families.members(@provider_families, :caldav)
  @caldav_based_provider_strings Families.member_strings(@provider_families, :caldav)
  @ews_providers Families.members(@provider_families, :ews)
  @ews_provider_strings Families.member_strings(@provider_families, :ews)
  @subscription_provider_strings Families.member_strings(@provider_families, :subscription)

  # Compile-time lookup from the provider's string form to its atom, covering
  # every statically known provider regardless of runtime toggles. Parsing
  # through this table keeps the string entry points total: no
  # `String.to_existing_atom/1` raise to rescue, and no dependence on whether
  # the atom happens to have been loaded yet.
  @provider_atoms Map.new(@providers ++ @dev_only_providers, &{Atom.to_string(&1), &1})

  # Providers whose CalDAV server URL is fixed and must never be edited by the
  # user, both during initial connection and reconnection. A provider absent
  # from this map allows the user to enter their own server URL.
  @locked_url_providers Family.fixed_urls()

  @locked_url_providers_by_string Map.new(@locked_url_providers, fn {atom_key, value} ->
                                    {Atom.to_string(atom_key), value}
                                  end)

  # Providers whose calls do not go through `CalendarCircuitBreaker`. A
  # provider-global breaker is the wrong shape for arbitrary per-user feed
  # hosts, and nothing in the ICS path calls it; a breaker process for it
  # would only ever report :closed. The demo provider calls nothing at all.
  @without_circuit_breaker [:ics_url, :demo]

  # Read provider settings from config
  @spec provider_settings() :: %{atom() => term()}
  defp provider_settings do
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
  Returns CalDAV-based providers.
  """
  @spec caldav_based_providers() :: list(atom())
  def caldav_based_providers, do: @caldav_based_providers

  @doc """
  Returns feed-subscription providers as strings, for matching against
  database string values such as `integration.provider`.
  """
  @spec subscription_provider_strings() :: list(String.t())
  def subscription_provider_strings, do: @subscription_provider_strings

  @doc """
  Returns CalDAV-based providers as strings, for matching against database
  string values such as `integration.provider`.
  """
  @spec caldav_based_provider_strings() :: list(String.t())
  def caldav_based_provider_strings, do: @caldav_based_provider_strings

  @doc """
  Returns the family a provider belongs to.

  Accepts the atom or the string form and answers identically for both: the
  database column and LiveView params carry the string. Anything the table
  does not know is `:other`.
  """
  @spec family_of(atom() | String.t() | any()) :: Families.t()
  def family_of(provider), do: Families.of(@family_index, provider)

  @doc """
  Checks whether a provider belongs to `family`. Accepts atom or string.

  The named predicates below are the readable spellings of the families that
  callers actually ask about; this is the general form.
  """
  @spec in_family?(atom() | String.t() | any(), Families.t()) :: boolean()
  def in_family?(provider, family), do: family_of(provider) == family

  @doc """
  Checks if a provider subscribes to a published feed.

  Subscriptions are read-only by construction: they can block availability
  but can never receive a booking.
  """
  @spec subscription?(atom() | String.t() | any()) :: boolean()
  def subscription?(provider), do: in_family?(provider, :subscription)

  @doc """
  Checks whether a provider can never receive a booking.

  A read-only provider's module refuses every write (`create_event/2` and
  friends answer `{:error, :read_only}`), so one of its calendars blocks
  availability but can never be the calendar an accepted booking is written
  to. Two things follow, and both are enforced by callers rather than here:
  such an integration must not be promoted to the user's primary, and its
  calendar entries must not be offered as a default booking target.

  Kept as its own list rather than derived from a family. It holds one member
  today, and deriving "cannot be written" from a protocol family would be
  wrong even so: `:exchange` was on this list while its provider was read-only
  and came off it when the write path landed, without the `:ews` family
  changing at all. What belongs here is a statement about a provider module's
  callbacks, not about the protocol it speaks.
  """
  @spec read_only?(atom() | String.t() | any()) :: boolean()
  def read_only?(provider) do
    case parse_known(provider) do
      {:ok, atom} -> atom in @read_only_providers
      {:error, :unknown} -> false
    end
  end

  @doc """
  The providers `read_only?/1` is true for, in the string form they are
  stored in, for a query that must leave them out.
  """
  @spec read_only_provider_strings() :: [String.t()]
  def read_only_provider_strings, do: @read_only_provider_strings

  @doc """
  Returns EWS-based providers.
  """
  @spec ews_providers() :: list(atom())
  def ews_providers, do: @ews_providers

  @doc """
  Returns EWS-based providers as strings, for matching against database
  string values such as `integration.provider`.
  """
  @spec ews_provider_strings() :: list(String.t())
  def ews_provider_strings, do: @ews_provider_strings

  @doc """
  Checks if a provider speaks Exchange Web Services. Accepts atom or string.
  """
  @spec ews?(atom() | String.t() | any()) :: boolean()
  def ews?(provider), do: in_family?(provider, :ews)

  # Order follows @providers — the canonical provider list — for deterministic results.
  @providers_with_circuit_breakers for p <- @providers, p not in @without_circuit_breaker, do: p

  @doc """
  Returns providers that have circuit-breaker monitoring enabled.

  Ordered to match `@providers`. Spans every provider family — CalDAV-based,
  OAuth and EWS; excludes the subscription feed and the demo provider.
  """
  @spec providers_with_circuit_breakers() :: list(atom())
  def providers_with_circuit_breakers, do: @providers_with_circuit_breakers

  @doc """
  Checks if a provider is valid.
  """
  @spec valid_provider?(atom()) :: boolean()
  def valid_provider?(provider) when is_atom(provider) do
    provider in all_providers_with_dev()
  end

  def valid_provider?(_provider), do: false

  @doc """
  Checks if a provider is OAuth-based. Accepts atom or string.
  """
  @spec oauth_provider?(atom() | String.t() | any()) :: boolean()
  def oauth_provider?(provider), do: in_family?(provider, :oauth)

  @doc """
  Checks if a provider is CalDAV-based. Accepts atom or string.
  """
  @spec caldav_based?(atom() | String.t() | any()) :: boolean()
  def caldav_based?(provider), do: in_family?(provider, :caldav)

  @doc """
  Whether the calendar grid writes a repeat rule to the provider's events:
  Google, Outlook and the CalDAV family. Exchange's writes carry none, so an
  Exchange event is never given one from the grid.
  """
  @spec writes_repeat_rules?(atom() | String.t() | any()) :: boolean()
  def writes_repeat_rules?(provider), do: oauth_provider?(provider) or caldav_based?(provider)

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
    do: @locked_url_providers |> Map.get(provider) |> translate_tooltip()

  def locked_url_for(provider) when is_binary(provider),
    do: @locked_url_providers_by_string |> Map.get(provider) |> translate_tooltip()

  def locked_url_for(_provider), do: nil

  # The table holds the tooltip as its msgid, so it is translated here, in the
  # locale of the process rendering it.
  defp translate_tooltip(nil), do: nil

  defp translate_tooltip(%{tooltip: tooltip} = locked),
    do: %{
      locked
      | tooltip: Gettext.dgettext(TymeslotWeb.Gettext, "integrations_calendar", tooltip)
    }

  @doc "How `provider` is presented. See `ProviderConfig.Metadata`."
  defdelegate metadata(provider), to: Metadata

  @doc "The provider's icon identifier."
  defdelegate icon(provider), to: Metadata

  @doc "The provider's description, translated."
  defdelegate description(provider), to: Metadata

  @doc "The provider's button text."
  defdelegate button_text(provider), to: Metadata

  @doc "The event the provider's button sends."
  defdelegate click_event(provider), to: Metadata

  @doc """
  Checks if provider requires circuit breaker monitoring.
  """
  @spec circuit_breaker_enabled?(atom()) :: boolean()
  def circuit_breaker_enabled?(provider), do: provider in @providers_with_circuit_breakers

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
    case Map.fetch(@provider_atoms, provider) do
      {:ok, atom} -> parse(atom)
      :error -> {:error, :unknown}
    end
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
    case Map.fetch(@provider_atoms, provider) do
      {:ok, atom} -> parse_known(atom)
      :error -> {:error, :unknown}
    end
  end

  def parse_known(_other), do: {:error, :unknown}

  @doc """
  Gets the display name for a provider.
  """
  @spec display_name(atom()) :: String.t()
  def display_name(provider) when provider in @caldav_based_providers,
    do: Family.display_name(provider)

  # The only descriptive name in this list rather than a brand, so it is the
  # only one that translates: "Nextcloud" reads the same in every locale, but
  # "Calendar subscription" is prose. Anything reaching the provider directory
  # gets this string from `Ics.Provider.display_name/0`, which the directory
  # prefers; this clause serves direct callers of this module. Both translate
  # the same msgid, so the two paths cannot disagree.
  def display_name(:ics_url),
    do: dgettext("integrations_calendar", "Calendar subscription")

  def display_name(:google), do: "Google Calendar"
  def display_name(:outlook), do: "Outlook Calendar"
  def display_name(:exchange), do: "Microsoft Exchange"
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

  def get_provider_module(:ics_url), do: Tymeslot.Integrations.Calendar.Ics.Provider

  def get_provider_module(:google), do: Tymeslot.Integrations.Calendar.Google.Provider
  def get_provider_module(:outlook), do: Tymeslot.Integrations.Calendar.Outlook.Provider
  def get_provider_module(:exchange), do: Tymeslot.Integrations.Calendar.Exchange.Provider
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
