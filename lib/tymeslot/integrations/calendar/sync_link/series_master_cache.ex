defmodule Tymeslot.Integrations.Calendar.SyncLink.SeriesMasterCache do
  @moduledoc """
  Short-lived cache for the recurring-series masters the mirror engine reads.

  Mirroring a recurring event needs the series master, because the cached row is
  an expanded instance whose rule and start describe that occurrence rather than
  the series. Fetching it is one `get_event/3` per source event — and the sync
  path enqueues one job *per link*, so the same master is fetched once for every
  calendar the organiser mirrors that series onto. Three links over a calendar
  holding fifty series is a hundred and fifty requests for fifty distinct
  masters, every sweep, against a quota shared with the paths a person is
  waiting on.

  The masters are identical across those links: the fan-out is a property of how
  many targets a source has, not of anything the master says. So the answer is
  cached against `{integration_id, master_id}` and the duplicates collapse.

  `CacheStore` also coalesces concurrent misses for the same key, which matters
  more here than the TTL does. The fan-out is *simultaneous* — the jobs for one
  source event are enqueued together and run together — so without coalescing
  the duplicate requests would all miss, all fetch, and all store the same
  answer before any of them had written it.

  The TTL is deliberately short. A master is not immutable: an organiser can
  change a series' rule, and a mirror written from a stale rule keeps the old
  shape until the next reconcile sweep notices. Two minutes is long enough to
  cover a single sweep's fan-out — which is the duplication worth removing — and
  short enough that a rule change is picked up on the following one rather than
  waiting out a cache.

  Only successful reads are cached. A failed fetch means "no placeholder this
  pass" and the sweep retries it; storing that would turn one provider hiccup
  into two minutes of skipped mirrors.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :calendar_series_master_cache,
    default_ttl: :timer.minutes(2),
    cleanup_interval: :timer.minutes(5)
end
