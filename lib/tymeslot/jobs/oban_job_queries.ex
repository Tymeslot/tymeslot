defmodule Tymeslot.Jobs.ObanJobQueries do
  @moduledoc """
  Query interface for Oban job-related database operations.
  """
  import Ecto.Query, warn: false
  alias Ecto.Changeset
  alias Oban.Job
  alias Oban.Worker
  alias Tymeslot.Repo

  @doc """
  Counts maintenance worker jobs in active states.

  `suspended` is treated as active: a suspended job has not reached a terminal
  state and may resume, so it must count as pending to keep this manual
  duplicate-prevention check in agreement with Oban's `unique: [states: ...]`
  guards on the workers.
  """
  @spec count_active_maintenance_jobs(String.t()) :: non_neg_integer()
  def count_active_maintenance_jobs(worker_name) do
    query =
      from(j in Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "executing", "suspended"],
        select: count(j.id)
      )

    Repo.one(query)
  end

  @doc """
  Returns distinct `user_id` values from `args` for jobs of the given worker
  whose `args["action"]` is in `actions` and whose state is not yet terminal
  (`available`, `scheduled`, `executing`, `retryable`, or `suspended`).

  `suspended` jobs are included so this check agrees with the workers' Oban
  `unique: [states: ...]` guards — a suspended job is still pending and must
  not allow a duplicate to be enqueued.

  Useful for workers that must avoid enqueueing additional actions for a user
  while any related action is still pending.
  """
  @spec user_ids_with_pending_jobs_for_actions(String.t(), [String.t()]) :: [integer()]
  def user_ids_with_pending_jobs_for_actions(worker_name, actions) do
    Repo.all(
      from(j in Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "executing", "retryable", "suspended"],
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
  @doc \"""
  Deletes any pending job for one meeting and one action.

  Generalises the reminder deletion below for the approval jobs, which key on
  the meeting alone. Worker names are normalised through `Worker.to_string/1`
  for the same reason: Oban stores them without the `Elixir.` prefix, so a raw
  module name would silently match nothing and leave the job to fire.
  """
  @spec delete_jobs_by_action(module(), String.t(), term()) :: {non_neg_integer(), nil}
  def delete_jobs_by_action(worker_module, action, meeting_id) do
    worker_name = Worker.to_string(worker_module)
    args_match = %{"action" => action, "meeting_id" => meeting_id}

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
  Deletes every pending job a worker holds for one meeting, on any queue.

  `delete_jobs_by_action/3` above is scoped to the `emails` queue, which is
  correct for the email jobs it was written for but silently matches nothing
  for a worker that runs anywhere else. The approval expiry job is one of
  those, and a missed deletion there is not cosmetic: it fires after the host
  has already answered and tries to expire a request that is no longer open.
  """
  @spec delete_meeting_jobs(module(), term()) :: {non_neg_integer(), nil}
  def delete_meeting_jobs(worker_module, meeting_id) do
    worker_name = Worker.to_string(worker_module)
    args_match = %{"meeting_id" => meeting_id}

    Repo.delete_all(
      from(j in Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("? @> ?::jsonb", j.args, type(^args_match, :map))
      )
    )
  end

  @doc """
  Deletes existing reminder email jobs for a meeting to avoid duplicates
  when rescheduling.
  """
  @spec delete_reminder_jobs_for_meeting(term(), module(), map()) ::
          {non_neg_integer(), nil}
  def delete_reminder_jobs_for_meeting(meeting_id, worker_module, reminder_params) do
    # Oban stores worker names without the "Elixir." prefix; `Worker.to_string/1`
    # normalises the module into that form so the match can't silently miss
    # every job.
    worker_name = Worker.to_string(worker_module)

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
  Deletes pending poll email jobs (deadline reminders and host nudges) for a poll.

  Used when a poll is confirmed or cancelled, so no reminder or nudge fires for a
  poll that is no longer collecting votes. Matches on the `poll_id` embedded in
  the job args regardless of action or variant.
  """
  @spec delete_poll_jobs(term(), module()) :: {non_neg_integer(), nil}
  def delete_poll_jobs(poll_id, worker_module) do
    # Oban stores worker names without the "Elixir." prefix; `Worker.to_string/1`
    # normalises the module into that form so the match can't silently miss.
    worker_name = Worker.to_string(worker_module)
    args_match = %{"poll_id" => poll_id}

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
