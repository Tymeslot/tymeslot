defmodule Tymeslot.Jobs.ObanJobQueries do
  @moduledoc """
  Query interface for Oban job-related database operations.
  """
  import Ecto.Query, warn: false
  alias Oban.Job
  alias Oban.Worker
  alias Tymeslot.Repo

  # Every state a job has not finished in: Oban's own `:incomplete` group
  # (available, scheduled, executing, retryable, suspended), the one a worker
  # declaring `unique: [states: :incomplete]` is held to. Every "is one still
  # pending?" question here asks it of this list, so none can let a duplicate
  # through that a worker's uniqueness would refuse.
  @incomplete_states Enum.map(Job.unique_states(:incomplete), &Atom.to_string/1)

  # The incomplete states a job can be deleted from: not `executing`, whose
  # process is running and would carry on, and not `suspended`, which belongs
  # to whoever suspended it.
  @deletable_states ~w(available scheduled retryable)

  @doc """
  Returns the args currently stored on a job's row, or `nil` when no row exists.

  A worker whose uniqueness covers `:executing` with `replace: [:args]` can have
  its row's args rewritten by a conflicting insert while it runs; the running
  process only ever sees the args it started with. Rereading the row is how such
  a worker notices the replacement before it finishes.
  """
  @spec get_current_args(Job.t()) :: map() | nil
  def get_current_args(%Job{id: id}) when is_integer(id) do
    Repo.one(from(j in Job, where: j.id == ^id, select: j.args))
  end

  def get_current_args(%Job{}), do: nil

  @doc """
  Counts the jobs of `worker` whose args contain `args` (JSON containment,
  served by Oban's GIN index on `args`) inserted at or after `since`, in any
  state. Returns the count and the oldest such job's `inserted_at`, `nil`
  when there is none.
  """
  @spec count_inserted_since(module(), map(), DateTime.t()) ::
          {non_neg_integer(), DateTime.t() | nil}
  def count_inserted_since(worker, args, %DateTime{} = since) when is_map(args) do
    worker_name = normalize_worker_name(worker)

    Repo.one(
      from(j in Job,
        where: j.worker == ^worker_name,
        where: fragment("? @> ?", j.args, ^args),
        where: j.inserted_at >= ^since,
        select: {count(j.id), min(j.inserted_at)}
      )
    )
  end

  @doc """
  Whether a job of `worker` whose args contain `args` is waiting out an
  error: `retryable` after a failed attempt, or `scheduled` by a snooze (an
  open circuit breaker, a provider's rate limit), which Oban counts in the
  job's `meta` under `"snoozed"`.
  """
  @spec backing_off?(module(), map()) :: boolean()
  def backing_off?(worker, args) when is_map(args) do
    worker_name = normalize_worker_name(worker)

    Repo.exists?(
      from(j in Job,
        where: j.worker == ^worker_name,
        where: fragment("? @> ?", j.args, ^args),
        where:
          j.state == "retryable" or
            (j.state == "scheduled" and fragment("(?->>'snoozed') IS NOT NULL", j.meta))
      )
    )
  end

  @doc """
  Counts maintenance worker jobs in active states.

  Active is every incomplete state, `retryable` and `suspended` included: a
  job waiting to retry has not finished either, and this manual
  duplicate-prevention check has to agree with the workers' uniqueness.
  """
  @spec count_active_maintenance_jobs(module() | String.t()) :: non_neg_integer()
  def count_active_maintenance_jobs(worker) do
    worker_name = normalize_worker_name(worker)

    query =
      from(j in Job,
        where: j.worker == ^worker_name,
        where: j.state in ^@incomplete_states,
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
  @spec user_ids_with_pending_jobs_for_actions(module() | String.t(), [String.t()]) :: [
          integer()
        ]
  def user_ids_with_pending_jobs_for_actions(worker, actions) do
    worker_name = normalize_worker_name(worker)

    Repo.all(
      from(j in Job,
        where: j.worker == ^worker_name,
        where: j.state in ^@incomplete_states,
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
  Returns the worker of each job in `ids` whose row still exists, as a map of
  job id to worker name. Ids without a row are left out.
  """
  @spec workers_by_id([integer()]) :: %{integer() => String.t()}
  def workers_by_id([]), do: %{}

  def workers_by_id(ids) when is_list(ids) do
    from(j in Job, where: j.id in ^ids, select: {j.id, j.worker})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Moves a job that is still `executing` to `discarded`, appending
  `error_info` to its errors.

  Guarded on the row's state rather than on the struct the caller read: a job
  that completed, or was retried, between that read and this write is left
  as it is and reported `{:error, :no_longer_executing}`.
  """
  @spec update_job_to_discarded(Job.t(), map()) ::
          {:ok, :discarded} | {:error, :no_longer_executing}
  def update_job_to_discarded(%Job{id: id}, error_info) do
    {count, _rows} =
      Repo.update_all(
        from(j in Job,
          where: j.id == ^id and j.state == "executing",
          update: [
            set: [
              state: "discarded",
              discarded_at: ^DateTime.utc_now(),
              errors: fragment("array_append(?, ?)", j.errors, type(^error_info, :map))
            ]
          ]
        ),
        []
      )

    if count == 1, do: {:ok, :discarded}, else: {:error, :no_longer_executing}
  end

  @doc """
  The args of every incomplete job of `worker` (Oban's `:incomplete` group:
  waiting, scheduled, retrying, executing and suspended).
  """
  @spec incomplete_job_args(module() | String.t()) :: [map()]
  def incomplete_job_args(worker) do
    worker_name = normalize_worker_name(worker)
    states = Enum.map(Job.unique_states(:incomplete), &Atom.to_string/1)

    Repo.all(
      from(j in Job, where: j.worker == ^worker_name and j.state in ^states, select: j.args)
    )
  end

  @doc """
  Narrows `query` to the rows of the binding named `binding` (an `id` column)
  that have no incomplete job of `worker` whose `args["user_id"]` is that id.

  "Incomplete" is Oban's own group (`Oban.Job.unique_states(:incomplete)`:
  waiting, scheduled, retrying, executing and suspended), the one a worker
  declaring `unique: [states: :incomplete]` is held to. A suspended job is
  counted because such a worker would reject a new insert while it exists, so
  a sweep that treated it as absent would try again on every run.
  """
  @spec without_incomplete_user_job(Ecto.Queryable.t(), module(), atom()) :: Ecto.Query.t()
  def without_incomplete_user_job(query, worker, binding) when is_atom(binding) do
    worker_name = normalize_worker_name(worker)

    where(
      query,
      [],
      not exists(
        from(j in Job,
          where: j.worker == ^worker_name,
          where: j.state in ^@incomplete_states,
          where: fragment("?->>'user_id' = ?::text", j.args, parent_as(^binding).id)
        )
      )
    )
  end

  @doc """
  Deletes any pending job for one meeting and one action.

  Generalises the reminder deletion below for the approval jobs, which key on
  the meeting alone. Worker names are normalised through `normalize_worker_name/1`
  for the same reason: Oban stores them without the `Elixir.` prefix, so a raw
  module name would silently match nothing and leave the job to fire.
  """
  @spec delete_jobs_by_action(module(), String.t(), term()) :: {non_neg_integer(), nil}
  def delete_jobs_by_action(worker_module, action, meeting_id) do
    args_match = %{"action" => action, "meeting_id" => meeting_id}
    delete_pending_jobs(worker_module, args_match, queue: "emails")
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
    args_match = %{"meeting_id" => meeting_id}
    delete_pending_jobs(worker_module, args_match)
  end

  @doc """
  Deletes existing reminder email jobs for a meeting to avoid duplicates
  when rescheduling.
  """
  @spec delete_reminder_jobs_for_meeting(term(), module(), map()) ::
          {non_neg_integer(), nil}
  def delete_reminder_jobs_for_meeting(meeting_id, worker_module, reminder_params) do
    args_match =
      Map.merge(
        %{"action" => "send_reminder_emails", "meeting_id" => meeting_id},
        reminder_params
      )

    delete_pending_jobs(worker_module, args_match, queue: "emails")
  end

  @doc """
  Returns `{meeting_id, reminder_value, reminder_unit}` for every reminder
  email job of `worker_module` still to run for one of `meeting_ids`, in one
  query however many meetings are asked about.

  "Still to run" is every non-terminal state, `executing` and `suspended`
  included: such a job has not finished, so its reminder is still coming.
  """
  @spec pending_reminder_jobs(module(), [term()]) :: [{term(), term(), term()}]
  def pending_reminder_jobs(_worker_module, []), do: []

  def pending_reminder_jobs(worker_module, meeting_ids) when is_list(meeting_ids) do
    worker_name = normalize_worker_name(worker_module)
    meeting_ids = Enum.map(meeting_ids, &to_string/1)

    Repo.all(
      from(j in Job,
        where: j.worker == ^worker_name,
        where: j.queue == "emails",
        where: j.state in ^@incomplete_states,
        where: fragment("?->>'action' = 'send_reminder_emails'", j.args),
        where: fragment("?->>'meeting_id' = ANY(?)", j.args, ^meeting_ids),
        select: {
          fragment("?->'meeting_id'", j.args),
          fragment("?->'reminder_value'", j.args),
          fragment("?->'reminder_unit'", j.args)
        }
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
    args_match = %{"poll_id" => poll_id}
    delete_pending_jobs(worker_module, args_match, queue: "emails")
  end

  @doc """
  Deletes every job still waiting to run whose args name `user_id` or one of
  `meeting_ids`, on any queue and for any worker. Run once an account has
  been deleted: nothing queued for it may run later, and no reminder may keep
  a guest's address in its args.

  A job already `executing` is left alone; it finds its rows gone and ends.
  """
  @spec delete_pending_account_jobs(integer(), [term()]) :: {non_neg_integer(), nil}
  def delete_pending_account_jobs(user_id, meeting_ids)
      when is_integer(user_id) and is_list(meeting_ids) do
    user_id = Integer.to_string(user_id)
    meeting_ids = Enum.map(meeting_ids, &to_string/1)

    Job
    |> where([j], j.state in @deletable_states)
    |> where(
      [j],
      fragment("?->>'user_id' = ?", j.args, ^user_id) or
        fragment("?->>'meeting_id' = ANY(?)", j.args, ^meeting_ids)
    )
    |> Repo.delete_all()
  end

  @doc "Deletes `worker_module`'s pending jobs whose args carry `user_id`."
  @spec delete_user_jobs(module(), integer()) :: {non_neg_integer(), nil}
  def delete_user_jobs(worker_module, user_id) when is_integer(user_id),
    do: delete_pending_jobs(worker_module, %{"user_id" => user_id})

  defp delete_pending_jobs(worker_module, args_match, opts \\ []) do
    worker_name = normalize_worker_name(worker_module)
    queue = Keyword.get(opts, :queue)

    Job
    |> where([j], j.worker == ^worker_name)
    |> where([j], j.state in @deletable_states)
    |> where([j], fragment("? @> ?::jsonb", j.args, type(^args_match, :map)))
    |> queue_filter(queue)
    |> Repo.delete_all()
  end

  defp queue_filter(query, nil), do: query
  defp queue_filter(query, queue), do: where(query, [j], j.queue == ^queue)

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

  @doc """
  Whether another job of `worker` for `meeting_id` started executing before
  `job` did and is executing still.

  "Before" is the order the jobs were fetched in, `attempted_at` with the id as
  a tie-break, not the order they were enqueued in. Enqueue order is not start
  order: priorities differ by action, a retry runs again under its old id, and
  a job snoozed behind a third one can wake after a newer job has begun. The
  order is strict, so of any two executing jobs exactly one sees the other,
  and the queue cannot wedge with both sides waiting.

  Oban's `unique` cannot express this: it decides whether a job is inserted at
  all, whereas this is about when an inserted job may run.
  """
  @spec earlier_job_executing?(module() | String.t(), term(), Job.t()) :: boolean()
  def earlier_job_executing?(worker, meeting_id, %Job{id: id, attempted_at: %DateTime{} = started})
      when is_integer(id) do
    worker_name = normalize_worker_name(worker)

    Repo.exists?(
      from(j in Job,
        where: j.id != ^id,
        where: j.state == "executing",
        where: j.worker == ^worker_name,
        where: fragment("?->>'meeting_id' = ?", j.args, ^to_string(meeting_id)),
        where: j.attempted_at < ^started or (j.attempted_at == ^started and j.id < ^id)
      )
    )
  end

  # Oban stores worker names without the "Elixir." prefix; `Worker.to_string/1`
  # normalises a module into that form so a match against `j.worker` can't
  # silently miss every job. Callers that already hold the stored name (e.g. a
  # worker's own `to_string(__MODULE__)`-shaped literal) pass it straight through.
  defp normalize_worker_name(worker) when is_atom(worker), do: Worker.to_string(worker)
  defp normalize_worker_name(worker) when is_binary(worker), do: worker
end
