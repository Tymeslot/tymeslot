defmodule Tymeslot.Integrations.Calendar.Shared.DiscoveryService do
  @moduledoc """
  Shared calendar discovery service for CalDAV-based providers.

  Provides unified discovery logic, delegating result caching (and concurrent
  request coalescing) to
  `Tymeslot.Integrations.Calendar.Shared.DiscoveryCache`.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryCache
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler

  @doc """
  Discovers calendars with caching support.

  ## Parameters
  - `provider` - The provider type (any atom returned by
    `Tymeslot.Integrations.Calendar.ProviderConfig.caldav_based_providers/0`)
  - `config` - Configuration map with base_url, username, password
  - `opts` - Options including :force_refresh to bypass cache

  ## Returns
  - `{:ok, calendars}` - List of discovered calendars
  - `{:error, reason}` - Error if discovery fails
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
        ) :: {:ok, list(map())} | {:error, String.t()}
  def discover_calendars(provider, config, opts \\ []) do
    cache_key = build_cache_key(provider, config)

    # A forced refresh drops any cached value so the fresh result is recomputed
    # and re-stored (rather than bypassing the cache entirely).
    if Keyword.get(opts, :force_refresh, false) do
      DiscoveryCache.invalidate(cache_key)
    end

    case DiscoveryCache.get_or_compute(cache_key, fn -> perform_discovery(provider, config) end) do
      {:ok, _calendars} = result ->
        result

      error ->
        # Never retain transient failures: a single network blip would
        # otherwise block rediscovery for the whole TTL.
        DiscoveryCache.invalidate(cache_key)
        error
    end
  end

  @doc """
  Discovers calendars for a specific integration with caching.

  ## Parameters
  - `integration` - The calendar integration record
  - `opts` - Options including :force_refresh

  ## Returns
  - `{:ok, calendars}` - List of discovered calendars
  - `{:error, reason}` - Error if discovery fails
  """
  @spec discover_for_integration(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          keyword()
        ) :: {:ok, list(map())} | {:error, String.t()}
  def discover_for_integration(integration, opts \\ []) do
    provider =
      try do
        String.to_existing_atom(integration.provider)
      rescue
        ArgumentError ->
          Logger.warning("Calendar integration has an unrecognised provider",
            integration_id: integration.id,
            provider: integration.provider
          )

          :unknown
      end

    config = build_config_from_integration(integration)

    case provider do
      :unknown -> {:error, "Unsupported provider: #{integration.provider}"}
      _other -> discover_calendars(provider, config, opts)
    end
  end

  @doc """
  Standardizes calendar data structure across providers.

  ## Parameters
  - `calendars` - List of calendar maps from various providers
  - `provider` - The provider type

  ## Returns
  - List of standardized calendar maps
  """
  @spec standardize_calendar_data(list(map()), atom()) :: list(map())
  def standardize_calendar_data(calendars, provider) do
    Enum.map(calendars, fn calendar ->
      %{
        id: calendar[:id] || calendar[:path] || generate_calendar_id(calendar, provider),
        path: calendar[:path] || calendar[:href],
        name: calendar[:name] || calendar[:displayname] || "Unnamed Calendar",
        type: calendar[:type] || "calendar",
        selected: calendar[:selected] || false,
        provider: provider,
        metadata: extract_metadata(calendar, provider)
      }
    end)
  end

  # Private functions

  defp perform_discovery(provider, config) do
    ErrorHandler.with_error_handling(
      provider,
      fn ->
        if ProviderConfig.caldav_based?(provider) do
          # apply/3 keeps the dispatch dynamic so the compiler does not warn
          # about non-caldav provider modules (debug/demo/nil) lacking a
          # `discover_calendars/1` arity — the caldav_based? gate above
          # already filters them out at runtime.
          provider_module = ProviderConfig.get_provider_module(provider)
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          client = apply(provider_module, :new, [config])
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(provider_module, :discover_calendars, [client])
        else
          {:error, "Unsupported provider: #{provider}"}
        end
      end,
      %{operation: "calendar_discovery"}
    )
  end

  defp build_cache_key(provider, config) do
    # Create a unique cache key based on provider and user
    user_id = "#{config[:username]}@#{extract_domain(config[:base_url])}"
    {provider, user_id}
  end

  defp extract_domain(url) do
    uri = URI.parse(url)
    uri.host || url
  end

  defp build_config_from_integration(integration) do
    %{
      base_url: integration.base_url,
      username: integration.username,
      password: integration.password,
      calendar_paths: integration.calendar_paths || []
    }
  end

  defp generate_calendar_id(calendar, provider) do
    # Generate a unique ID for calendars that don't have one
    path = calendar[:path] || calendar[:href] || ""
    name = calendar[:name] || ""

    :crypto.hash(:md5, "#{provider}:#{path}:#{name}")
    |> Base.encode16(case: :lower)
    |> String.slice(0..7)
  end

  defp extract_metadata(calendar, provider) do
    # Extract provider-specific metadata
    %{
      color: calendar[:color],
      description: calendar[:description],
      timezone: calendar[:timezone],
      created_at: calendar[:created_at],
      updated_at: calendar[:updated_at],
      supported_components: calendar[:supported_components],
      provider_specific: extract_provider_specific_metadata(calendar, provider)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp extract_provider_specific_metadata(calendar, :nextcloud) do
    %{
      share_status: calendar[:share_status],
      owner: calendar[:owner],
      permissions: calendar[:permissions]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp extract_provider_specific_metadata(_calendar, _provider), do: %{}
end
