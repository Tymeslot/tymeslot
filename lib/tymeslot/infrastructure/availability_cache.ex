defmodule Tymeslot.Infrastructure.AvailabilityCache do
  @moduledoc """
  ETS-based cache for availability data using the shared CacheStore.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :availability_cache,
    default_ttl: :timer.minutes(2),
    cleanup_interval: :timer.minutes(5)

  @doc """
  Cache key helpers for consistent key generation.
  """
  @spec month_availability_key(integer(), integer(), integer(), String.t(), integer() | nil) ::
          {atom(), integer(), integer(), integer(), String.t(), integer() | nil}
  def month_availability_key(user_id, year, month, timezone, duration) do
    {:month_availability, user_id, year, month, timezone, duration}
  end

  @doc """
  Cache key for range-based availability lookups.
  """
  @spec availability_range_key(integer(), Date.t(), Date.t(), String.t(), integer() | nil) ::
          {atom(), integer(), Date.t(), Date.t(), String.t(), integer() | nil}
  def availability_range_key(user_id, start_date, end_date, timezone, duration) do
    {:range_availability, user_id, start_date, end_date, timezone, duration}
  end
end
