defmodule Tymeslot.Infrastructure.DashboardCache do
  @moduledoc """
  ETS-based cache for dashboard data using the shared CacheStore.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :dashboard_cache,
    default_ttl: :timer.minutes(5),
    cleanup_interval: :timer.minutes(10)
end
