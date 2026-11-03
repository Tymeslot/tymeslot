defmodule Tymeslot.Workers.CalendarCachePruneWorker do
  @moduledoc """
  Daily maintenance job that prunes stale data from the calendar event cache.

  Two cleanup passes:
  1. **Old events** — removes events whose `end_at` falls before the oldest
     date any sync still reaches. A row outside that window will never be
     refreshed again, so it serves no purpose in the cache; a row inside it
     would be re-fetched on the next run, and deleting it only to write it
     back is churn.

     The cutoff is therefore derived from `Sync.window_past_days/0`
     rather than fixed. It was previously a flat 90 days, justified by a
     60-day CalDAV window that no longer exists: every provider now reads a
     year back, so the prune was deleting a year's worth of live rows every
     night for the next sync to re-insert. The grace period keeps the two
     bounds from meeting exactly, since they are computed at different times
     of day.
  2. **Inactive integrations** — removes events belonging to integrations the
     user has deactivated. These events are invisible in the UI and would only
     be cleaned up when the integration is fully deleted (via cascade), so
     pruning them proactively keeps the table lean.

  After both, the rules and the attendee series entries
  (`Tymeslot.Meetings.AttendeeNotifications.SeriesEntries`) of the series
  the cache no longer holds are forgotten. A series' entries go only once
  every one of them has also ended, and was last written, before the
  cutoff, since a write to a whole series empties its cache until the next
  sync and marks its entries as written.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1,
    unique: [period: 86_400, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  require Logger

  alias Tymeslot.Integrations.Calendar.IntegrationCacheQueries
  alias Tymeslot.Integrations.Calendar.SeriesRules
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Meetings.AttendeeNotifications.SeriesEntries

  @grace_days 30

  @impl Oban.Worker
  def perform(_job) do
    retention_days = retention_days()
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    old_count = IntegrationCacheQueries.prune_ended_before(cutoff)
    inactive_count = IntegrationCacheQueries.prune_inactive_integrations()
    SeriesRules.forget_all_orphans()
    series_entries_count = SeriesEntries.forget_stale(cutoff)

    Logger.info("Calendar cache prune completed",
      old_events_pruned: old_count,
      inactive_events_pruned: inactive_count,
      series_entries_pruned: series_entries_count,
      retention_days: retention_days
    )

    :ok
  end

  # Read at runtime rather than folded into a module attribute. Calling
  # `ProviderConfig` at compile time makes this worker a compile-time
  # dependency of it, and `mix xref graph --label compile-connected` is
  # budgeted at 25 edges; this one pushed it to 26.
  @spec retention_days() :: pos_integer()
  defp retention_days, do: Sync.window_past_days() + @grace_days
end
