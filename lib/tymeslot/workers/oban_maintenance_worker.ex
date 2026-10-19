defmodule Tymeslot.Workers.ObanMaintenanceWorker do
  @moduledoc """
  Performs regular maintenance on Oban jobs:

  1. Cleans up stuck jobs in "executing" state
  2. Deletes delivery claims (`Tymeslot.Workers.DeliveryClaims`) whose job
     Oban has pruned
  3. Provides metrics and logging for job health monitoring, and raises an
     `:oban_jobs_force_discarded` admin alert for the jobs it discards

  This worker runs every 30 minutes, from the Oban crontab, to ensure job
  queue health. It does not schedule itself.

  Discarding a stuck job is the last rung of the ladder in
  `Tymeslot.Infrastructure.ObanRescue`, not the first: `Oban.Lifeline` returns
  an abandoned job to `available` hours earlier, so anything still `executing`
  by the time this sweep sees it is a row the lifeline never reached, on an
  installation that has none configured or whose leader is unreachable. The
  threshold comes from `ObanRescue.discard_after_hours/0` for that reason: a
  discarded job never runs again, so this sweep must never pre-empt the rescue
  that would have recovered the work.

  Terminal-job retention (completed/discarded/cancelled) is handled by
  `Oban.Plugins.Pruner`, not here: its `max_age` is a week in every
  environment, so a second sweep with a longer window would never find
  anything left to delete.
  """

  use Oban.Worker,
    queue: :maintenance,
    priority: 3,
    max_attempts: 3,
    # One run per crontab slot (every 30 minutes). Uniqueness counts from
    # the previous job's insertion, so a period equal to the interval would
    # swallow the next slot's job whenever the cron plugin inserts it a
    # moment early; a little under the interval cannot.
    unique: [period: 1740]

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes
  alias Tymeslot.Infrastructure.ObanRescue
  alias Tymeslot.Jobs
  alias Tymeslot.Workers.DeliveryClaims

  @stuck_job_threshold_hours ObanRescue.discard_after_hours()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.info("Starting Oban maintenance", args: args)

    {:ok, stuck_count} = cleanup_stuck_jobs()
    claims_pruned = DeliveryClaims.prune_orphaned()

    Logger.info("Oban maintenance completed",
      stuck_jobs_cleaned: stuck_count,
      delivery_claims_pruned: claims_pruned
    )

    {:ok, %{stuck_cleaned: stuck_count, claims_pruned: claims_pruned}}
  end

  @doc false
  # Discards each of `stuck_jobs`, as found by the scan, and returns those it
  # discarded. Public so a test can hand it a job that finished after the scan.
  @spec discard_stuck_jobs([Oban.Job.t()]) :: [Oban.Job.t()]
  def discard_stuck_jobs(stuck_jobs) do
    Enum.filter(stuck_jobs, fn job ->
      case transition_stuck_job_to_discarded(job) do
        {:ok, _result} ->
          true

        # It finished between the scan and the discard: the race the
        # guarded discard exists for, and nothing to clean.
        {:error, :no_longer_executing} ->
          Logger.info("Stuck job finished before it was cleaned", job_id: job.id)
          false
      end
    end)
  end

  # Private functions

  defp cleanup_stuck_jobs do
    threshold = DateTime.add(DateTime.utc_now(), -@stuck_job_threshold_hours, :hour)

    discarded = threshold |> Jobs.get_stuck_executing_jobs() |> discard_stuck_jobs()

    cleaned_count = length(discarded)

    if cleaned_count > 0 do
      Logger.warning("Cleaned up stuck jobs",
        count: cleaned_count,
        threshold_hours: @stuck_job_threshold_hours
      )
    end

    # A job moved straight to `discarded` emits no job telemetry, so nothing
    # else would tell the operator that its work was dropped.
    ObanOutcomes.report_force_discarded(discarded, __MODULE__)

    {:ok, cleaned_count}
  end

  defp transition_stuck_job_to_discarded(job) do
    # Calculate how long the job was stuck (guard against nil attempted_at)
    stuck_duration =
      if job.attempted_at do
        DateTime.diff(DateTime.utc_now(), job.attempted_at, :second)
      else
        0
      end

    # Build error information
    error_info = %{
      at: DateTime.utc_now(),
      attempt: job.attempt,
      error: "Job stuck in executing state for #{format_duration(stuck_duration)}",
      kind: "stuck_job_cleanup",
      cleanup_metadata: %{
        worker: job.worker,
        queue: job.queue,
        attempted_at: job.attempted_at,
        stuck_duration_seconds: stuck_duration,
        cleanup_reason: "automatic_maintenance"
      }
    }

    # Update the job to discarded state
    Jobs.update_job_to_discarded(job, error_info)
  end

  defp format_duration(seconds) when seconds < 3600 do
    "#{div(seconds, 60)} minutes"
  end

  defp format_duration(seconds) when seconds < 86_400 do
    "#{Float.round(seconds / 3600, 1)} hours"
  end

  defp format_duration(seconds) do
    "#{Float.round(seconds / 86400, 1)} days"
  end
end
