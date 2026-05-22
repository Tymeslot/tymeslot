defmodule Tymeslot.Jobs.ObanJobQueries do
  @moduledoc """
  Query interface for Oban job-related database operations.
  """
  import Ecto.Query, warn: false
  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.Repo

  @doc """
  Counts maintenance worker jobs in active states.
  """
  @spec count_active_maintenance_jobs(String.t()) :: non_neg_integer()
  def count_active_maintenance_jobs(worker_name) do
    query =
      from(j in Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "executing"],
        select: count(j.id)
      )

    Repo.one(query)
  end

  @doc """
  Returns distinct `user_id` values from `args` for jobs of the given worker
  whose `args["action"]` is in `actions` and whose state is not yet terminal
  (`available`, `scheduled`, `executing`, or `retryable`).

  Useful for workers that must avoid enqueueing additional actions for a user
  while any related action is still pending.
  """
  @spec user_ids_with_pending_jobs_for_actions(String.t(), [String.t()]) :: [integer()]
  def user_ids_with_pending_jobs_for_actions(worker_name, actions) do
    Repo.all(
      from(j in Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("?->>'action' = ANY(?)", j.args, ^actions),
        distinct: true,
        select: fragment("(?->>'user_id')::bigint", j.args)
      )
    )
  end

  @doc """
  Gets all stuck executing jobs older than the given threshold.
  """
  @spec get_stuck_executing_jobs(DateTime.t()) :: [Job.t()]
  def get_stuck_executing_jobs(threshold_datetime) do
    query =
      from(j in Job,
        where: j.state == "executing",
        where: j.attempted_at < ^threshold_datetime,
        select: j
      )

    Repo.all(query)
  end

  @doc """
  Updates a job to discarded state with error information.
  """
  @spec update_job_to_discarded(Job.t(), map()) ::
          {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def update_job_to_discarded(job, error_info) do
    existing_errors = job.errors || []

    job
    |> Changeset.change(%{
      state: "discarded",
      discarded_at: DateTime.utc_now(),
      errors: existing_errors ++ [error_info]
    })
    |> Repo.update()
  end

  @doc """
  Deletes old jobs in terminal states (completed, discarded, cancelled).
  Returns {deleted_count, nil}.
  """
  @spec delete_old_terminal_jobs(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_old_terminal_jobs(cutoff_date) do
    Repo.delete_all(
      from(j in Job,
        where: j.state in ["completed", "discarded", "cancelled"],
        where: j.inserted_at < ^cutoff_date
      )
    )
  end

  @doc """
  Acknowledges pending reminder jobs for a meeting.
  Reminder emails re-fetch meeting data at send time, so no job updates are required.
  """
  @spec update_pending_reminder_jobs(map()) :: {:ok, integer()}
  def update_pending_reminder_jobs(_meeting) do
    # Since EmailWorker.perform (via EmailWorkerHandlers) re-fetches the meeting
    # from the database before sending any email, we don't actually need to
    # update the job arguments. The worker will automatically pick up the
    # newly added video_room_id/meeting_url from the database.

    # We just return success here to satisfy the Orchestrator.
    {:ok, 0}
  end

  @doc """
  Deletes existing reminder email jobs for a meeting to avoid duplicates
  when rescheduling.
  """
  @spec delete_reminder_jobs_for_meeting(term(), String.t(), map()) ::
          {non_neg_integer(), nil}
  def delete_reminder_jobs_for_meeting(meeting_id, worker_name, reminder_params) do
    args_match =
      Map.merge(
        %{"action" => "send_reminder_emails", "meeting_id" => meeting_id},
        reminder_params
      )

    Repo.delete_all(
      from(j in Job,
        where: j.queue == "emails",
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("? @> ?::jsonb", j.args, type(^args_match, :map))
      )
    )
  end

  @doc """
  Lists queues with accumulated available jobs exceeding the threshold.
  Returns a list of `{queue_name, count}` tuples.
  """
  @spec list_accumulated_jobs(DateTime.t()) :: [{String.t(), non_neg_integer()}]
  def list_accumulated_jobs(recent_cutoff) do
    Repo.all(
      from(j in Job,
        where: j.state == "available",
        where: j.inserted_at > ^recent_cutoff,
        group_by: j.queue,
        select: {j.queue, count(j.id)}
      )
    )
  end

  @doc """
  Lists queues with available jobs older than the cutoff time.
  Returns a list of `{queue_name, count}` tuples.
  """
  @spec list_stuck_available_jobs(DateTime.t(), DateTime.t()) ::
          [{String.t(), non_neg_integer()}]
  def list_stuck_available_jobs(cutoff_time, recent_cutoff) do
    Repo.all(
      from(j in Job,
        where: j.state == "available",
        where: j.inserted_at < ^cutoff_time,
        where: j.inserted_at > ^recent_cutoff,
        group_by: j.queue,
        select: {j.queue, count(j.id)}
      )
    )
  end

  @doc """
  Lists queues with retryable jobs past their scheduled retry time.
  Returns a list of `{queue_name, count}` tuples.
  """
  @spec list_stuck_retryable_jobs(DateTime.t(), DateTime.t(), DateTime.t()) ::
          [{String.t(), non_neg_integer()}]
  def list_stuck_retryable_jobs(now, cutoff_time, recent_cutoff) do
    Repo.all(
      from(j in Job,
        where: j.state == "retryable",
        where: j.scheduled_at < ^now,
        where: j.scheduled_at < ^cutoff_time,
        where: j.inserted_at > ^recent_cutoff,
        group_by: j.queue,
        select: {j.queue, count(j.id)}
      )
    )
  end
end
