defmodule Tymeslot.Integrations.Calendar.Shared.DiscoveryService do
  @moduledoc """
  Shared calendar discovery service with caching support.

  Provides unified discovery logic for CalDAV-based providers with
  result caching to improve performance and reduce server load.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV
  alias Tymeslot.Integrations.Calendar.Nextcloud
  alias Tymeslot.Integrations.Calendar.Radicale
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler

  # Cache discovery results for 5 minutes
  @cache_ttl_seconds 300
  @cache_table :calendar_discovery_cache

  @doc """
  Initializes the discovery cache ETS table.
  Should be called during application startup.
  """
  @spec init_cache() :: :ok
  def init_cache do
    if :ets.info(@cache_table) == :undefined do
      :ets.new(@cache_table, [:set, :public, :named_table, {:read_concurrency, true}])
    end

    :ok
  end

  @doc """
  Discovers calendars with caching support.

  ## Parameters
  - `provider` - The provider type (:caldav, :nextcloud, :radicale)
  - `config` - Configuration map with base_url, username, password
  - `opts` - Options including :force_refresh to bypass cache

  ## Returns
  - `{:ok, calendars}` - List of discovered calendars
  - `{:error, reason}` - Error if discovery fails
  """
  @spec discover_calendars(atom(), map(), keyword()) :: {:ok, list(map())} | {:error, String.t()}
  def discover_calendars(provider, config, opts \\ []) do
    force_refresh = Keyword.get(opts, :force_refresh, false)
    cache_key = build_cache_key(provider, config)

    if force_refresh do
      perform_discovery(provider, config)
    else
      with :miss <- get_cached_result(cache_key),
           {:ok, calendars} = result <- perform_discovery(provider, config) do
        Logger.debug("Cache miss, performing discovery for #{provider}")
        cache_result(cache_key, calendars)
        result
      else
        {:ok, calendars} ->
          Logger.debug("Using cached discovery results for #{provider}")
          {:ok, calendars}

        error ->
          error
      end
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
  @spec discover_for_integration(map(), keyword()) :: {:ok, list(map())} | {:error, String.t()}
  def discover_for_integration(integration, opts \\ []) do
    provider =
      try do
        String.to_existing_atom(integration.provider)
      rescue
        ArgumentError -> :unknown
      end

    config = build_config_from_integration(integration)

    case provider do
      :unknown -> {:error, "Unsupported provider: #{integration.provider}"}
      _ -> discover_calendars(provider, config, opts)
    end
  end

  @doc """
  Clears the discovery cache for a specific provider and user.

  ## Parameters
  - `provider` - The provider type
  - `config` - Configuration map with user credentials
  """
  @spec clear_cache(atom(), map()) :: :ok
  def clear_cache(provider, config) do
    cache_key = build_cache_key(provider, config)
    :ets.delete(@cache_table, cache_key)
    :ok
  end

  @doc """
  Clears all expired cache entries.
  Should be called periodically by a background job.
  """
  @spec clear_expired_cache() :: :ok
  def clear_expired_cache do
    ensure_cache_exists()

    current_time = System.system_time(:second)

    :ets.select_delete(@cache_table, [
      {
        {:"$1", {:"$2", :"$3"}},
        [{:<, :"$3", current_time}],
        [true]
      }
    ])

    :ok
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
        case provider do
          :caldav ->
            perform_caldav_discovery(config)

          :nextcloud ->
            perform_nextcloud_discovery(config)

          :radicale ->
            perform_radicale_discovery(config)

          _ ->
            {:error, "Unsupported provider: #{provider}"}
        end
      end,
      %{operation: "calendar_discovery"}
    )
  end

  defp perform_caldav_discovery(config) do
    # Create CalDAV client and discover calendars
    client = CalDAV.Provider.new(config)
    CalDAV.Provider.discover_calendars(client)
  end

  defp perform_nextcloud_discovery(config) do
    # Create Nextcloud client and discover calendars
    client = Nextcloud.Provider.new(config)
    Nextcloud.Provider.discover_calendars(client)
  end

  defp perform_radicale_discovery(config) do
    # Create Radicale client and discover calendars
    client = Radicale.Provider.new(config)
    Radicale.Provider.discover_calendars(client)
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

  defp get_cached_result(cache_key) do
    ensure_cache_exists()

    case :ets.lookup(@cache_table, cache_key) do
      [{^cache_key, {calendars, expiry}}] ->
        if System.system_time(:second) < expiry do
          {:ok, calendars}
        else
          :ets.delete(@cache_table, cache_key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_result(cache_key, calendars) do
    ensure_cache_exists()

    expiry = System.system_time(:second) + @cache_ttl_seconds
    :ets.insert(@cache_table, {cache_key, {calendars, expiry}})
    :ok
  end

  defp ensure_cache_exists do
    if :ets.info(@cache_table) == :undefined do
      init_cache()
    end
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
