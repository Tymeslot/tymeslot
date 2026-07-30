defmodule Tymeslot.Integrations.Calendar.Discovery do
  @moduledoc """
  The single choke point for calendar discovery: rate-limits and caches a
  discovery request, then dispatches it to the resolved provider module.
  For an already-persisted integration, the provider module is resolved
  exactly once and reused for both the rate-limit/cache wrapper and the
  dispatch itself — no second, independent resolution deeper in the call
  chain.

  Every discovery path — an already-persisted integration's "refresh
  calendar list", raw not-yet-persisted credentials
  (`discover_calendars_for_credentials/5`), and the opportunistic
  CalDAV/Radicale pre-discovery during integration creation
  (`maybe_discover_calendars/1`) — funnels through here. CalDAV-family
  providers are metered and cached under the `:discovery`
  `Tymeslot.Integrations.Shared.ConnectionProbe` bucket; OAuth providers
  (Google, Outlook) are deliberately not, since their discovery is a single
  call to a fixed vendor endpoint rather than a server-side fetch of a
  user-supplied host — there is no outbound-request amplification to guard
  against, and no shared result worth caching.

  `Tymeslot.Integrations.Calendar.Shared.DiscoveryService` holds only the
  residue every discovery path shares (cache-key derivation, standardizing
  provider results); it has no provider dispatch and does not meter
  anything itself.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Shared.{DiscoveryCache, DiscoveryService, ErrorHandler}
  alias Tymeslot.Integrations.Shared.ConnectionProbe

  @caldav_provider_strings ProviderConfig.caldav_based_provider_strings()

  @type discovery_credentials :: %{
          required(:url) => String.t(),
          required(:username) => String.t(),
          required(:password) => String.t()
        }

  @doc """
  Discover calendars for an existing integration using provider-specific logic.
  Returns {:ok, calendars} with standardized entries.

  CalDAV-family providers are metered and cached here, charged to the
  integration's owner — every caller (dashboard "refresh calendar list", the
  post-OAuth auto-select) already sits behind the per-user
  `calendar_refresh` rate limit, so this is always a real, resolvable actor.
  OAuth providers dispatch straight to the callback, unmetered (see
  moduledoc).
  """
  @spec discover_calendars_for_integration(map()) :: {:ok, list()} | {:error, any()}
  def discover_calendars_for_integration(%{provider: provider} = integration) do
    with {:ok, provider_atom} <- ProviderConfig.parse_known(provider),
         {:ok, provider_module} <- provider_module_for(provider_atom) do
      if ProviderConfig.caldav_based?(provider_atom) do
        metered_integration_discovery(provider_atom, provider_module, integration)
      else
        provider_module.discover_calendars_for_integration(integration)
      end
    else
      _other -> {:error, "Unknown provider: #{provider}"}
    end
  end

  @doc """
  Discovers calendars for a CalDAV-family provider given raw connection
  config, with caching and rate limiting.

  This is the metered/cached discovery core, used both by
  `discover_calendars_for_credentials/5` (not-yet-persisted credentials) and
  by `discover_caldav_calendar_paths/1` (the creation-flow's opportunistic
  pre-discovery). `Tymeslot.Integrations.Calendar.Connection.validate_connection/2`
  also calls it directly for its CalDAV branch.

  ## Parameters
  - `provider` - The provider type (any atom returned by
    `Tymeslot.Integrations.Calendar.ProviderConfig.caldav_based_providers/0`)
  - `config` - Configuration map with base_url, username, password
  - `opts` - Options:
    - `:force_refresh` - bypass the cache
    - `:actor` - required. Charged only on a real cache miss (i.e. only
      when discovery actually reaches the network), never on a cache hit.

  ## Returns
  - `{:ok, calendars}` - List of discovered calendars
  - `{:error, reason}` - Error if discovery fails, including the rate-limited
    and unattributable-actor cases
  """
  @spec discover_calendars(
          atom(),
          %{
            required(:base_url) => String.t(),
            required(:username) => String.t(),
            required(:password) => String.t(),
            optional(:calendar_paths) => list(String.t())
          },
          keyword()
        ) ::
          {:ok, list(map())}
          | {:error, {:rate_limited, String.t()}}
          | {:error, :unattributable}
          | {:error, atom() | String.t()}
  def discover_calendars(provider_atom, config, opts \\ []) do
    case Keyword.fetch(opts, :actor) do
      {:ok, actor} ->
        cache_key = DiscoveryService.build_cache_key(provider_atom, config)
        force_refresh = Keyword.get(opts, :force_refresh, false)

        probe_and_cache(cache_key, actor, force_refresh, fn ->
          ErrorHandler.with_error_handling(
            provider_atom,
            fn -> dispatch_caldav_discovery(provider_atom, config) end,
            %{operation: "calendar_discovery"}
          )
        end)

      :error ->
        Logger.error("Calendar discovery attempted without a resolved actor",
          provider: provider_atom
        )

        {:error, "Calendar discovery could not be attributed to your account. Please try again."}
    end
  end

  @doc """
  Discover calendars using raw credentials before creating an integration.
  Returns {:ok, %{calendars: standardized, discovery_credentials: %{...}}} or {:error, message}.
  """
  @spec discover_calendars_for_credentials(
          atom() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, %{calendars: list(), discovery_credentials: discovery_credentials()}}
          | {:error, String.t()}
  def discover_calendars_for_credentials(provider, url, username, password, opts \\ []) do
    force_refresh = Keyword.get(opts, :force_refresh, false)

    case resolve_provider_atom(provider) do
      {:ok, provider_atom} ->
        with {:ok, provider_module} <- provider_module_for(provider_atom),
             client_config <- %{base_url: url, username: username, password: password},
             :ok <-
               (case provider_module.validate_config(client_config) do
                  :ok -> :ok
                  {:error, reason} -> {:error, {:validation, reason}}
                end),
             {:ok, calendars} <-
               (case discover_calendars(provider_atom, client_config,
                       force_refresh: force_refresh,
                       actor: Keyword.fetch!(opts, :actor)
                     ) do
                  {:ok, cals} -> {:ok, cals}
                  {:error, reason} -> {:error, {:discovery, reason}}
                end) do
          standardized = DiscoveryService.standardize_calendar_data(calendars, provider_atom)

          {:ok,
           %{
             calendars: standardized,
             discovery_credentials: %{url: url, username: username, password: password}
           }}
        else
          error -> credentials_discovery_error(error, provider, provider_atom)
        end

      {:error, :unknown_provider} ->
        {:error, "Unknown provider: #{provider}"}
    end
  end

  @doc """
  Maybe perform discovery for CalDAV/Radicale attrs during creation and inject paths.
  Non-CalDAV providers pass through unchanged.

  This is a narrow helper used by creation flows to opportunistically set
  calendar_paths for CalDAV-like providers, deferring all actual discovery
  logic to `discover_calendars/3`.
  """
  @spec maybe_discover_calendars(map()) :: {:ok, map()}
  def maybe_discover_calendars(%{provider: provider} = attrs)
      when provider in @caldav_provider_strings do
    case discover_caldav_calendar_paths(attrs) do
      {:ok, paths} when is_list(paths) and paths != [] ->
        {:ok, Map.put(attrs, :calendar_paths, paths)}

      _other ->
        {:ok, attrs}
    end
  end

  def maybe_discover_calendars(attrs), do: {:ok, attrs}

  # Internal helper that returns just the list of paths for CalDAV/Radicale.
  # Production callers pass atom-keyed attrs from Creation.prepare_attrs/2,
  # which always carries :user_id — routed through discover_calendars/3 so
  # this opportunistic pre-discovery is metered like every other discovery
  # call.
  @spec discover_caldav_calendar_paths(map()) :: {:ok, list(String.t())} | {:error, String.t()}
  defp discover_caldav_calendar_paths(%{provider: provider} = attrs) do
    # Built explicitly rather than passing `attrs` through: `discover_calendars/3`
    # declares the exact config shape it accepts, and handing it the whole
    # creation-attrs map (which carries `:user_id`, `:name` and more) breaks
    # that contract.
    client_config = %{
      base_url: attrs[:base_url],
      username: attrs[:username],
      password: attrs[:password],
      calendar_paths: attrs[:calendar_paths] || []
    }

    with {:ok, provider_atom} <- ProviderConfig.parse_known(provider),
         {:ok, calendars} <-
           discover_calendars(provider_atom, client_config, actor: {:user, attrs[:user_id]}) do
      {:ok, extract_calendar_paths(calendars)}
    else
      {:error, reason} -> {:error, format_discovery_error(reason)}
    end
  end

  # A rate-limit refusal is already a finished, user-facing sentence ("You've
  # reached the limit of N …"). Running it through `format_provider_error/3`
  # would replace it with a generic provider error and drop the only guidance
  # the user can act on, so it passes through untouched.
  defp credentials_discovery_error({:error, {:discovery, {:rate_limited, message}}}, _p, _atom),
    do: {:error, message}

  # `discover_calendars/3` leaves `ConnectionProbe`'s `:unattributable`
  # refusal tagged rather than flattening it — build the user-facing text
  # here, the caller-facing edge for this flow.
  defp credentials_discovery_error({:error, {:discovery, :unattributable}}, _p, _atom),
    do: {:error, "Calendar discovery could not be attributed to your account. Please try again."}

  defp credentials_discovery_error({:error, {:validation, reason}}, _provider, provider_atom),
    do:
      {:error,
       ErrorHandler.format_provider_error(reason, provider_atom, %{operation: "validation"})}

  defp credentials_discovery_error({:error, {:discovery, reason}}, _provider, provider_atom),
    do:
      {:error,
       ErrorHandler.format_provider_error(reason, provider_atom, %{operation: "discovery"})}

  defp credentials_discovery_error({:error, :unknown_provider}, provider, _provider_atom),
    do: {:error, "Unknown provider: #{provider}"}

  defp resolve_provider_atom(p) do
    case ProviderRegistry.validate_provider(p) do
      {:ok, provider_atom} -> {:ok, provider_atom}
      {:error, _reason} -> {:error, :unknown_provider}
    end
  end

  defp provider_module_for(provider_atom) do
    case ProviderRegistry.get_provider(provider_atom) do
      {:ok, mod} -> {:ok, mod}
      {:error, _reason} -> {:error, :unknown_provider}
    end
  end

  # Wraps an already-persisted CalDAV integration's
  # `discover_calendars_for_integration/1` callback in the same
  # rate-limit/cache funnel `discover_calendars/3` uses for raw credentials.
  # The provider callback itself stays pure I/O (decrypts credentials, builds
  # its config, calls `new/1` + `discover_calendars/1`); metering/caching the
  # whole callback call rather than reaching inside it keeps each provider's
  # own config-building (some decrypt, Nextcloud also standardizes) out of
  # this module.
  #
  # Cache key is the integration's id rather than username@host: every
  # caller here always passes `force_refresh: true` (a "refresh calendar
  # list" always wants a fresh network fetch), so the cache is invalidated
  # before every compute and only ever coalesces truly concurrent calls for
  # the same integration.
  defp metered_integration_discovery(provider_atom, provider_module, integration) do
    cache_key = {provider_atom, integration.id}
    actor = {:user, integration.user_id}

    probe_and_cache(cache_key, actor, true, fn ->
      ErrorHandler.with_error_handling(
        provider_atom,
        fn -> provider_module.discover_calendars_for_integration(integration) end,
        %{operation: "calendar_discovery"}
      )
    end)
  end

  # Shared cache/invalidate plumbing for both `discover_calendars/3` (raw
  # credentials) and `metered_integration_discovery/3` (a persisted
  # integration) — the two only differ in the cache key and the compute
  # closure, so both funnel through here rather than duplicating the
  # get_or_compute/invalidate dance.
  defp probe_and_cache(cache_key, actor, force_refresh?, compute) do
    if force_refresh? do
      DiscoveryCache.invalidate(cache_key)
    end

    case DiscoveryCache.get_or_compute(cache_key, fn -> run_probe(actor, compute) end) do
      {:ok, _calendars} = result ->
        result

      error ->
        # Never retain transient failures: a single network blip would
        # otherwise block rediscovery for the whole TTL.
        DiscoveryCache.invalidate(cache_key)
        error
    end
  end

  # Charges `actor` before ever touching the network, through
  # `ConnectionProbe` — the same choke point every other connection test
  # goes through, under the `:discovery` bucket rather than any one
  # provider's own bucket. Runs inside the cache-compute closure (only
  # called by `DiscoveryCache.get_or_compute/2` on a miss), so a cache hit
  # never draws from the budget.
  defp run_probe(actor, compute) do
    ConnectionProbe.probe(%ConnectionProbe.Request{
      scope: :interactive,
      actor: actor,
      bucket: :discovery,
      # Deliberately nothing to validate here — the discovery config's own
      # shape is checked by the provider module before `new/1` is called.
      validate: fn -> :ok end,
      run: compute
    })
  end

  # `provider_module` is a runtime-resolved variable, so this dispatch is
  # already dynamic — no `apply/3` (and no Credo suppression) needed to keep
  # the compiler from expecting non-caldav provider modules (debug/demo/nil)
  # to implement the optional `discover_calendars/1` callback; the
  # `caldav_based?` gate below filters them out before this is ever called
  # on one.
  defp dispatch_caldav_discovery(provider_atom, config) do
    if ProviderConfig.caldav_based?(provider_atom) do
      {:ok, provider_module} = provider_module_for(provider_atom)
      config |> provider_module.new() |> provider_module.discover_calendars()
    else
      {:error, "Unsupported provider: #{provider_atom}"}
    end
  end

  # Helpers migrated from legacy discovery context
  defp extract_calendar_paths(calendars) when is_list(calendars) do
    calendars
    |> Enum.map(fn
      %{href: href} -> href
      %{"href" => href} -> href
      %{"path" => path} -> path
      %{path: path} -> path
      path when is_binary(path) -> path
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp format_discovery_error(:unauthorized), do: "Authentication failed during discovery"
  defp format_discovery_error(:not_found), do: "Calendar server not found"
  defp format_discovery_error(:network_error), do: "Network error during discovery"
  defp format_discovery_error(reason) when is_binary(reason), do: reason
  defp format_discovery_error(_arg), do: "Calendar discovery failed"
end
