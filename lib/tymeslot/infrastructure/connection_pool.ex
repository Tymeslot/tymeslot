defmodule Tymeslot.Infrastructure.ConnectionPool do
  @moduledoc """
  Manages HTTP connection pools for the application.
  """

  @doc """
  Configures hackney connection pools for the application.
  Should be called during application startup.
  """
  @spec setup_pools() :: :ok
  def setup_pools do
    # Default pool for general HTTP requests
    :ok =
      :hackney_pool.start_pool(:default,
        timeout: 60_000,
        max_connections: 100
      )

    # Dedicated pool for CalDAV connections
    # Smaller pool since we typically only connect to one CalDAV server
    :ok =
      :hackney_pool.start_pool(:caldav_pool,
        # CalDAV operations can be slow
        timeout: 120_000,
        max_connections: 20
      )

    # Pool for external APIs (MiroTalk, etc)
    :ok =
      :hackney_pool.start_pool(:external_api_pool,
        timeout: 30_000,
        max_connections: 50
      )

    :ok
  end

  @doc """
  Gets the appropriate pool name for a given URL or service type.
  """
  @spec get_pool(String.t() | atom()) :: atom()
  def get_pool(url) when is_binary(url) do
    cond do
      String.contains?(url, "caldav") or String.contains?(url, "radicale") ->
        :caldav_pool

      String.contains?(url, "mirotalk") ->
        :external_api_pool

      true ->
        :default
    end
  end

  def get_pool(:caldav), do: :caldav_pool
  def get_pool(:external_api), do: :external_api_pool
  def get_pool(_), do: :default

  @doc """
  Returns pool statistics for monitoring.
  """
  @spec pool_stats(atom()) :: {:ok, map()}
  def pool_stats(pool_name \\ :default) do
    stats = :hackney_pool.get_stats(pool_name)
    {:ok, format_stats(stats)}
  end

  defp format_stats(stats) when is_list(stats) do
    %{
      name: Keyword.get(stats, :name),
      max_connections: Keyword.get(stats, :max),
      in_use_count: Keyword.get(stats, :in_use_count, 0),
      free_count: Keyword.get(stats, :free_count, 0),
      queue_count: Keyword.get(stats, :queue_count, 0)
    }
  end
end
