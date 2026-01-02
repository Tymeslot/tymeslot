defmodule Tymeslot.Infrastructure.DashboardCache do
  @moduledoc """
  Simple ETS-based cache for dashboard data.
  Reduces database queries for data that doesn't change frequently.
  """

  use GenServer

  @table_name :dashboard_cache
  @default_ttl :timer.minutes(5)

  # Client API

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Get a value from cache or compute it if missing/expired.
  """
  @spec get_or_compute(term(), (-> term()), integer()) :: term()
  def get_or_compute(key, fun, ttl \\ @default_ttl) do
    case lookup(key) do
      {:ok, value} -> value
      :miss -> compute_and_store(key, fun, ttl)
    end
  end

  @doc """
  Invalidate a specific cache key.
  """
  @spec invalidate(term()) :: true
  def invalidate(key) do
    :ets.delete(@table_name, key)
  end

  @doc """
  Invalidate all cache entries matching a pattern.
  Example: invalidate_pattern({:user_stats, user_id, :_})
  """
  @spec invalidate_pattern(term()) :: true
  def invalidate_pattern(pattern) do
    :ets.match_delete(@table_name, {pattern, :_, :_})
  end

  @doc """
  Clear all cache entries.
  """
  @spec clear_all() :: true
  def clear_all do
    :ets.delete_all_objects(@table_name)
  end

  # Server callbacks

  @impl true
  def init(_args) do
    table =
      :ets.new(@table_name, [
        :named_table,
        :public,
        :set,
        read_concurrency: true
      ])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp lookup(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, key) do
      [{^key, value, expiry}] when expiry > now ->
        {:ok, value}

      _ ->
        :miss
    end
  end

  defp compute_and_store(key, fun, ttl) do
    value = fun.()
    expiry = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table_name, {key, value, expiry})
    value
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table_name, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(10))
  end

  @doc """
  Cache key helpers for consistent key generation.
  """
  @spec integration_status_key(integer()) :: {atom(), integer()}
  def integration_status_key(user_id), do: {:integration_status, user_id}
end
