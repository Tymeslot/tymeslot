defmodule Tymeslot.Integrations.Calendar.Shared.DiscoveryCache do
  @moduledoc """
  Short-lived cache for CalDAV calendar-discovery results.

  Discovery is a slow remote round-trip (PROPFIND against the provider's CalDAV
  endpoint), so repeated lookups for the same account within the TTL collapse
  onto a single request. Backed by ETS through
  `Tymeslot.Infrastructure.CacheStore`, which also coalesces concurrent misses
  for the same key — a stampede of simultaneous discovery requests (e.g. several
  dashboard tabs) hits the provider once rather than once per caller.

  Keys are `{provider, "username@host"}` tuples built by
  `Tymeslot.Integrations.Calendar.Shared.DiscoveryService`. Only successful
  (`{:ok, calendars}`) results are retained; the caller invalidates transient
  failures so they are not served stale.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :calendar_discovery_cache,
    default_ttl: :timer.minutes(5),
    cleanup_interval: :timer.minutes(10)
end
