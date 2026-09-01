defmodule Tymeslot.Workers.ObanQueueMonitorWorker do
  @moduledoc """
  Monitors Oban queues for issues like:
  - Jobs accumulating beyond thresholds
  - Jobs stuck in available state (backlog)
  - Jobs stuck in retryable state past their scheduled retry time

  Runs hourly via Oban.Plugins.Cron to detect queue health issues and alert admins.

  Note: This worker runs in a dedicated :monitoring queue separate from :maintenance
  to ensure it can detect issues even if the maintenance queue itself is stuck.

  ## Required Database Indexes

  For optimal performance on large installations, ensure these indexes exist:

      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_oban_jobs_monitoring
        ON oban_jobs (state, queue, inserted_at)
        WHERE state IN ('available', 'retryable');

      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_oban_jobs_scheduled_monitoring
        ON oban_jobs (state, queue, scheduled_at, inserted_at)
        WHERE state = 'retryable';

  These indexes support the group_by queries used for queue health checks.
  Without them, queries may be slow or timeout on systems with millions of jobs.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Jobs

  # Default alert thresholds (can be overridden via application config)
  @default_thresholds %{
    job_accumulation_threshold: 100,
    stuck_job_threshold: 10,
    stuck_job_age_hours: 2,
    recent_jobs_days: 7
  }

  # Get a threshold value from config or use default
  # Uses explicit nil check so that 0 is respected as a valid threshold
  defp get_threshold(key) do
    config = Application.get_env(:tymeslot, :oban_monitoring, @default_thresholds)

    case Map.get(config, key) do
      nil -> Map.fetch!(@default_thresholds, key)
      value -> value
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.debug("ObanQueueMonitorWorker performing queue health check")

    safe_check("check_job_accumulation", &check_job_accumulation/0)
    safe_check("check_stuck_available_jobs", &check_stuck_available_jobs/0)
    safe_check("check_stuck_retryable_jobs", &check_stuck_retryable_jobs/0)

    :ok
  end

  defp safe_check(name, check_fn) do
    check_fn.()
  rescue
    error ->
      Logger.error("Queue monitor check failed",
        check: name,
        error: Exception.message(error)
      )
  end

  # Check for job accumulation in queues
  # Uses batched alerts to avoid spam when many queues are unhealthy
  defp check_job_accumulation do
    threshold = get_threshold(:job_accumulation_threshold)
    recent_days = get_threshold(:recent_jobs_days)
    recent_cutoff = DateTime.add(DateTime.utc_now(), -recent_days, :day)

    unhealthy_queues =
      recent_cutoff
      |> Jobs.list_accumulated_jobs()
      |> Enum.filter(fn {_queue, count} -> count > threshold end)

    if unhealthy_queues != [] do
      Logger.warning("Oban queues accumulating jobs",
        affected_queues: unhealthy_queues,
        threshold: threshold
      )

      AdminAlerts.report(:oban_jobs_accumulating,
        summary: "Oban queues accumulating jobs above threshold",
        context: %{
          affected_queues: unhealthy_queues,
          total_affected: length(unhealthy_queues),
          threshold: threshold
        }
      )
    end
  end

  # Check for jobs stuck in available state (true backlog)
  # Available jobs should be picked up immediately, so old available jobs indicate
  # workers aren't running or are overwhelmed
  defp check_stuck_available_jobs do
    threshold = get_threshold(:stuck_job_threshold)
    age_hours = get_threshold(:stuck_job_age_hours)
    recent_days = get_threshold(:recent_jobs_days)

    cutoff_time = DateTime.add(DateTime.utc_now(), -age_hours, :hour)
    recent_cutoff = DateTime.add(DateTime.utc_now(), -recent_days, :day)

    unhealthy_queues =
      cutoff_time
      |> Jobs.list_stuck_available_jobs(recent_cutoff)
      |> Enum.filter(fn {_queue, count} -> count > threshold end)

    if unhealthy_queues != [] do
      Logger.warning("Oban queues have stuck available jobs",
        affected_queues: unhealthy_queues,
        age_hours: age_hours
      )

      AdminAlerts.report(:oban_queue_stuck,
        summary: "Oban queues have stuck jobs in available state",
        context: %{
          affected_queues: unhealthy_queues,
          total_affected: length(unhealthy_queues),
          job_state: "available",
          age_hours: age_hours,
          threshold: threshold
        }
      )
    end
  end

  # Check for jobs stuck in retryable state past their scheduled retry time
  # Retryable jobs have a scheduled_at timestamp. If that time has passed and they're
  # still retryable, something is wrong (queue disabled, workers down, etc.)
  defp check_stuck_retryable_jobs do
    threshold = get_threshold(:stuck_job_threshold)
    age_hours = get_threshold(:stuck_job_age_hours)
    recent_days = get_threshold(:recent_jobs_days)

    now = DateTime.utc_now()
    cutoff_time = DateTime.add(now, -age_hours, :hour)
    recent_cutoff = DateTime.add(now, -recent_days, :day)

    unhealthy_queues =
      now
      |> Jobs.list_stuck_retryable_jobs(cutoff_time, recent_cutoff)
      |> Enum.filter(fn {_queue, count} -> count > threshold end)

    if unhealthy_queues != [] do
      Logger.warning("Oban queues have stuck retryable jobs",
        affected_queues: unhealthy_queues,
        age_hours: age_hours
      )

      AdminAlerts.report(:oban_queue_stuck,
        summary: "Oban queues have stuck jobs in retryable state",
        context: %{
          affected_queues: unhealthy_queues,
          total_affected: length(unhealthy_queues),
          job_state: "retryable",
          age_hours: age_hours,
          threshold: threshold
        }
      )
    end
  end
end
