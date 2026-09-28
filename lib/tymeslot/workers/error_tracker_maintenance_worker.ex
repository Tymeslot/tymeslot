defmodule Tymeslot.Workers.ErrorTrackerMaintenanceWorker do
  @moduledoc """
  Daily housekeeping for ErrorTracker, which runs storage-only: there is no
  dashboard, so nobody resolves an error by hand, and without this job every
  error would stay unresolved and every occurrence would be kept forever.

  Each run, with `window` being `:error_tracking_resolve_after_days`:

  1. **Resolve.** An unresolved error not seen for `window` days is marked
     resolved. Should it happen again, ErrorTracker moves it back to
     unresolved and emits its regression event, which raises an admin alert
     through `Tymeslot.Infrastructure.ErrorTracking.Alerter`. Muted errors
     are resolved too: the mute still silences a regression, and a muted
     error that has gone quiet is as finished as any other. The one cost is
     that once the error is pruned (step 2) its mute goes with it, so an
     occurrence after that raises a fresh "new error" alert; after two
     quiet windows that is a reasonable thing to hear about.

  2. **Prune.** Resolved errors are deleted with their occurrences through
     `ErrorTracker.Plugins.Pruner.prune_errors/1`. The pruner measures age
     from `last_occurrence_at`, not from when the error was resolved (the
     schema records no resolved-at), so passing the same window would delete
     an error in the very run that resolved it, and a recurrence would then
     arrive as a new error with no history instead of a regression. The
     prune age is therefore two windows: an auto-resolved error stays
     resolved, and visible as a regression if it returns, for one full
     window before it is deleted.

  3. **Trim.** An unresolved error that keeps recurring is never resolved,
     so its occurrences are trimmed instead: those older than the window go,
     except the newest `:error_tracking_occurrences_kept` of the error,
     which are always kept whatever their age. Inside the window an error
     keeps at most its newest `:error_tracking_occurrences_max`, so a
     chronic failure cannot fill the table for a month before it ages out.

  The tunables are read on every run, so `config/runtime.exs` can set them.
  Maintenance runs whether or not error tracking is switched on
  (`ERROR_TRACKING_ENABLED`): what was stored before it was switched off
  still ages out on the same schedule.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking.ErrorTrackingQueries

  @impl Oban.Worker
  def perform(_job) do
    # Read at run time rather than compiled in, so `config/runtime.exs` can
    # tune them without a rebuild.
    resolve_after_days = Application.get_env(:tymeslot, :error_tracking_resolve_after_days, 30)
    cutoff = DateTime.add(DateTime.utc_now(), -resolve_after_days, :day)

    resolved = ErrorTrackingQueries.resolve_last_seen_before(cutoff)
    pruned = ErrorTrackingQueries.prune_resolved(:timer.hours(24 * 2 * resolve_after_days))

    trimmed =
      ErrorTrackingQueries.trim_unresolved_occurrences(
        cutoff,
        Application.get_env(:tymeslot, :error_tracking_occurrences_kept, 50),
        Application.get_env(:tymeslot, :error_tracking_occurrences_max, 1_000)
      )

    Logger.info("ErrorTracker maintenance completed",
      errors_resolved: resolved,
      errors_pruned: pruned,
      occurrences_trimmed: trimmed,
      resolve_after_days: resolve_after_days
    )

    :ok
  end
end
