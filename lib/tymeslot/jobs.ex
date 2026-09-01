defmodule Tymeslot.Jobs do
  @moduledoc """
  Background-job context: the entry point for everything callers need to know
  about Oban's job table.

  Workers schedule their own jobs through `Oban` directly; what this context
  covers is the other direction, reading and repairing the queue. Maintenance
  workers ask it whether a run of their own is already pending, the reminder
  pipeline asks it to retire jobs whose meeting moved, and the queue monitor
  asks it what has accumulated or got stuck.

  Callers outside `Tymeslot.Jobs` use this module rather than
  `Tymeslot.Jobs.ObanJobQueries`, which is the data-access layer behind it.
  """

  alias Tymeslot.Jobs.ObanJobQueries

  @doc """
  Returns the args currently stored on a job's row, or `nil` when no row exists.

  A worker whose uniqueness covers `:executing` with `replace: [:args]` can have
  its row's args rewritten by a conflicting insert while it runs; the running
  process only ever sees the args it started with. Rereading the row is how such
  a worker notices the replacement before it finishes.
  """
  defdelegate get_current_args(job), to: ObanJobQueries

  @doc """
  Counts maintenance worker jobs in active states.

  A worker calls this with its own module before enqueuing, so a scheduled run
  cannot pile up behind one that has not finished.
  """
  defdelegate count_active_maintenance_jobs(worker_module), to: ObanJobQueries

  @doc """
  User ids that already have a pending job for any of `actions` on `worker_module`.
  """
  defdelegate user_ids_with_pending_jobs_for_actions(worker_module, actions), to: ObanJobQueries

  @doc """
  Jobs still marked `executing` since before `threshold_datetime`.
  """
  defdelegate get_stuck_executing_jobs(threshold_datetime), to: ObanJobQueries

  @doc """
  Moves a job to `discarded`, recording `error_info` against it.
  """
  defdelegate update_job_to_discarded(job, error_info), to: ObanJobQueries

  @doc """
  Deletes the reminder jobs a meeting no longer needs.
  """
  defdelegate delete_reminder_jobs_for_meeting(meeting_id, worker_module, reminder_params),
    to: ObanJobQueries

  @doc """
  Deletes pending poll email jobs (deadline reminders and host nudges) for a poll.
  """
  defdelegate delete_poll_jobs(poll_id, worker_module), to: ObanJobQueries

  @doc """
  Queues holding jobs older than `recent_cutoff`, with their depth.
  """
  defdelegate list_accumulated_jobs(recent_cutoff), to: ObanJobQueries

  @doc """
  Jobs sitting `available` past `cutoff_time` with nothing recent behind them.
  """
  defdelegate list_stuck_available_jobs(cutoff_time, recent_cutoff), to: ObanJobQueries

  @doc """
  Jobs sitting `retryable` past `cutoff_time` with nothing recent behind them.
  """
  defdelegate list_stuck_retryable_jobs(now, cutoff_time, recent_cutoff), to: ObanJobQueries
end
