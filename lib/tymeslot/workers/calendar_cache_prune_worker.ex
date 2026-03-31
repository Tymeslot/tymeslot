defmodule Tymeslot.Workers.CalendarCachePruneWorker do
  @moduledoc """
  Daily maintenance job that prunes stale data from the calendar event cache.

  Two cleanup passes:
  1. **Old events** — removes events whose `end_at` is more than 90 days in
     the past. Sync workers only fetch a bounded window (e.g. 60 days back for
     CalDAV), so events outside that window will never be refreshed and serve
     no purpose in the cache.
  2. **Inactive integrations** — removes events belonging to integrations the
     user has deactivated. These events are invisible in the UI and would only
     be cleaned up when the integration is fully deleted (via cascade), so
     pruning them proactively keeps the table lean.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]

  require Logger

  alias Tymeslot.DatabaseQueries.CalendarEventCacheQueries

  @retention_days 90

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

    old_count = CalendarEventCacheQueries.prune_ended_before(cutoff)
    inactive_count = CalendarEventCacheQueries.prune_inactive_integrations()

    Logger.info("Calendar cache prune completed",
      old_events_pruned: old_count,
      inactive_events_pruned: inactive_count,
      retention_days: @retention_days
    )

    :ok
  end
end
