defmodule Tymeslot.Workers.ObanMaintenanceWorker do
  @moduledoc """
  Performs regular maintenance on Oban jobs:

  1. Cleans up stuck jobs in "executing" state
  2. Deletes old failed/discarded jobs after 90 days
  3. Provides metrics and logging for job health monitoring

  This worker runs every 30 minutes to ensure job queue health.
  """

  use Oban.Worker,
    queue: :maintenance,
    priority: 3,
    max_attempts: 3,
    # Prevent overlapping runs (30 minutes)
    unique: [period: 1800]

  require Logger

  alias Tymeslot.DatabaseQueries.ObanJobQueries

  @stuck_job_threshold_hours 4
  @old_job_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.info("Starting Oban maintenance", args: args)

    with {:ok, stuck_count} <- cleanup_stuck_jobs(),
         {:ok, deleted_count} <- delete_old_jobs() do
      Logger.info("Oban maintenance completed",
        stuck_jobs_cleaned: stuck_count,
        old_jobs_deleted: deleted_count
      )

      # Schedule next run
      schedule_next_run()

      {:ok, %{stuck_cleaned: stuck_count, old_deleted: deleted_count}}
    end
  end

  @doc """
  Schedules the next maintenance run in 30 minutes.
  """
  @spec schedule_next_run() :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_next_run do
    %{action: "maintenance"}
    # 30 minutes
    |> new(schedule_in: 1800)
    |> Oban.insert()
  end

  @doc """
  Starts the maintenance worker if not already scheduled.
  """
  @spec start_if_not_scheduled() :: :ok | {:ok, Oban.Job.t()} | {:error, term()}
  def start_if_not_scheduled do
    # Check if a maintenance job is already scheduled
    scheduled_count =
      ObanJobQueries.count_active_maintenance_jobs("Tymeslot.Workers.ObanMaintenanceWorker")

    if scheduled_count == 0 do
      Logger.info("Scheduling initial Oban maintenance job")
      schedule_next_run()
    end
  end

  # Private functions

  defp cleanup_stuck_jobs do
    threshold = DateTime.add(DateTime.utc_now(), -@stuck_job_threshold_hours, :hour)

    # Find stuck executing jobs
    stuck_jobs = ObanJobQueries.get_stuck_executing_jobs(threshold)

    # Clean up each stuck job
    cleaned_count =
      Enum.reduce(stuck_jobs, 0, fn job, count ->
        case transition_stuck_job_to_discarded(job) do
          {:ok, _} ->
            count + 1

          {:error, reason} ->
            Logger.error("Failed to clean stuck job",
              job_id: job.id,
              reason: reason
            )

            count
        end
      end)

    if cleaned_count > 0 do
      Logger.warning("Cleaned up stuck jobs",
        count: cleaned_count,
        threshold_hours: @stuck_job_threshold_hours
      )
    end

    {:ok, cleaned_count}
  end

  defp transition_stuck_job_to_discarded(job) do
    # Calculate how long the job was stuck
    stuck_duration = DateTime.diff(DateTime.utc_now(), job.attempted_at, :second)

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
    ObanJobQueries.update_job_to_discarded(job, error_info)
  end

  defp delete_old_jobs do
    cutoff_date = DateTime.add(DateTime.utc_now(), -@old_job_retention_days, :day)

    # Delete old completed, discarded, and cancelled jobs
    {deleted_count, _} = ObanJobQueries.delete_old_terminal_jobs(cutoff_date)

    if deleted_count > 0 do
      Logger.info("Deleted old jobs",
        count: deleted_count,
        retention_days: @old_job_retention_days,
        states: ["completed", "discarded", "cancelled"]
      )
    end

    {:ok, deleted_count}
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
