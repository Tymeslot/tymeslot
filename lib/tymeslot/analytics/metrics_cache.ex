defmodule Tymeslot.Analytics.MetricsCache do
  @moduledoc """
  Short-lived, per-organizer cache for computed booking-analytics metrics.

  Each dashboard load otherwise reruns half a dozen aggregate queries (counts,
  the per-source attribution merge, the device breakdown and the visits-by-day
  series). Repeated loads and tab switches within the TTL collapse onto a single
  computation per organizer/window.

  This is a dedicated cache, separate from `Tymeslot.Infrastructure.DashboardCache`:
  the shared `CacheStore` macro owns one ETS table per module, so the analytics
  metrics get their own TTL, cleanup and invalidation rather than sharing the
  general dashboard cache's table.

  Backed by ETS through `Tymeslot.Infrastructure.CacheStore`. The ETS backend is
  an implementation detail behind `fetch/4` — swapping it for a distributed cache
  later is a change to this module alone, not its callers.

  ## Tenant isolation

  Cache keys are built by `key/3` and **always** include the organizer's
  `user_id`. Never call `get_or_compute/3` with a hand-rolled key that omits it,
  or one organizer could be served another's metrics.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :analytics_metrics_cache,
    default_ttl: :timer.seconds(60),
    cleanup_interval: :timer.minutes(5)

  @doc """
  Computes `fun` once per `{user_id, range_days, time_zone}` window and caches
  the result for the default TTL. The user id keeps each organizer's data
  isolated; the time zone is part of the key because the visits-by-day series
  is bucketed in it, so a zone change must not be served the old buckets.
  """
  @spec fetch(integer(), pos_integer(), String.t(), (-> result)) :: result when result: var
  def fetch(user_id, range_days, time_zone, fun)
      when is_integer(user_id) and is_integer(range_days) and is_binary(time_zone) do
    get_or_compute(key(user_id, range_days, time_zone), fun)
  end

  @doc """
  Drops the cached metrics for one organizer/window so the next `fetch/4`
  recomputes from the database. Backs the dashboard's manual "Refresh" action,
  which must reflect just-recorded visits without waiting out the TTL.
  """
  @spec invalidate(integer(), pos_integer(), String.t()) :: true
  def invalidate(user_id, range_days, time_zone)
      when is_integer(user_id) and is_integer(range_days) and is_binary(time_zone) do
    invalidate(key(user_id, range_days, time_zone))
  end

  @doc """
  Cache key for an organizer's metrics over a range of days, bucketed in a
  time zone.
  """
  @spec key(integer(), pos_integer(), String.t()) ::
          {:analytics_metrics, integer(), pos_integer(), String.t()}
  def key(user_id, range_days, time_zone),
    do: {:analytics_metrics, user_id, range_days, time_zone}
end
