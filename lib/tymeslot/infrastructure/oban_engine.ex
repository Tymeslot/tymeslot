defmodule Tymeslot.Infrastructure.ObanEngine do
  @moduledoc """
  The Oban engine: `Oban.Engines.Basic`, plus the enqueuer's correlation id
  carried into the job.

  A job enqueued while handling a request, or by another job, is part of that
  work, and its log lines and errors should say so. Every job inserted while
  a valid `correlation_id` is in the caller's Logger metadata gets it as
  `meta["correlation_id"]`, and the caller's `user_id` as `meta["user_id"]`
  unless the job's args already name a user. `Tymeslot.Infrastructure.ObanLogger`
  restores both at `job:start` through `inherited_context/1`.

  Oban has no insert hook, and the engine is the one place every insert
  (`Oban.insert/2`, `insert_all/2`, the `Ecto.Multi` forms, and the jobs one
  job enqueues for another) passes through, so no call site can forget it.
  Everything but the two inserts is `Oban.Engines.Basic` unchanged.

  A key the caller put in `meta` itself is never overwritten.
  """

  @behaviour Oban.Engine

  alias Ecto.Changeset
  alias Oban.Engine
  alias Oban.Engines.Basic
  alias Tymeslot.Infrastructure.CorrelationId

  # A job's args name its user under one of these: `user_id` by convention,
  # `organizer_user_id` in the meeting-driven video jobs.
  # Stored args are string-keyed; a changeset's may still hold atom keys.
  @user_id_arg_keys ["user_id", "organizer_user_id", :user_id, :organizer_user_id]

  @impl Engine
  def insert_job(conf, changeset, opts),
    do: Basic.insert_job(conf, put_caller_context(changeset), opts)

  @impl Engine
  def insert_all_jobs(conf, changesets, opts),
    do: Basic.insert_all_jobs(conf, Enum.map(changesets, &put_caller_context/1), opts)

  @impl Engine
  defdelegate init(conf, opts), to: Basic
  @impl Engine
  defdelegate put_meta(conf, meta, key, value), to: Basic
  @impl Engine
  defdelegate check_meta(conf, meta, running), to: Basic
  @impl Engine
  defdelegate refresh(conf, meta), to: Basic
  @impl Engine
  defdelegate shutdown(conf, meta), to: Basic
  @impl Engine
  defdelegate fetch_jobs(conf, meta, running), to: Basic
  @impl Engine
  defdelegate stage_jobs(conf, queryable, opts), to: Basic
  @impl Engine
  defdelegate prune_jobs(conf, queryable, opts), to: Basic
  @impl Engine
  defdelegate rescue_jobs(conf, queryable, opts), to: Basic
  @impl Engine
  defdelegate check_available(conf), to: Basic
  @impl Engine
  defdelegate complete_job(conf, job), to: Basic
  @impl Engine
  defdelegate discard_job(conf, job), to: Basic
  @impl Engine
  defdelegate error_job(conf, job, seconds), to: Basic
  @impl Engine
  defdelegate snooze_job(conf, job, seconds), to: Basic
  @impl Engine
  defdelegate cancel_job(conf, job), to: Basic
  @impl Engine
  defdelegate cancel_all_jobs(conf, queryable), to: Basic
  @impl Engine
  defdelegate delete_job(conf, job), to: Basic
  @impl Engine
  defdelegate delete_all_jobs(conf, queryable), to: Basic
  @impl Engine
  defdelegate retry_job(conf, job), to: Basic
  @impl Engine
  defdelegate retry_all_jobs(conf, queryable), to: Basic
  @impl Engine
  defdelegate update_job(conf, job, changes), to: Basic

  @doc """
  Returns the context a job inherited from its enqueuer, as a keyword list for
  `Tymeslot.Infrastructure.ErrorTracking.put_context/1`: `correlation_id`
  when the job's meta holds a valid one, and `user_id` when its args name a
  user or, failing that, its meta does. A key with no usable value is left
  out.
  """
  @spec inherited_context(Oban.Job.t()) :: keyword()
  def inherited_context(%Oban.Job{args: args, meta: meta}) do
    meta = if is_map(meta), do: meta, else: %{}

    correlation_id = meta["correlation_id"]
    user_id = args_user_id(args) || meta["user_id"]

    Enum.reject(
      [
        correlation_id: if(CorrelationId.valid?(correlation_id), do: correlation_id),
        user_id: if(is_integer(user_id) or is_binary(user_id), do: user_id)
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp put_caller_context(%Changeset{} = changeset) do
    case caller_meta(Changeset.get_field(changeset, :args)) do
      empty when map_size(empty) == 0 ->
        changeset

      caller_meta ->
        meta = Changeset.get_field(changeset, :meta) || %{}
        Changeset.put_change(changeset, :meta, Map.merge(caller_meta, meta))
    end
  end

  # Nothing is carried without a correlation id: a user id alone would tie
  # the job to its enqueuer without the id that finds the enqueuer's logs.
  defp caller_meta(args) do
    metadata = Logger.metadata()
    correlation_id = metadata[:correlation_id]

    if CorrelationId.valid?(correlation_id) do
      user_id = if is_nil(args_user_id(args)), do: metadata[:user_id]

      Map.reject(
        %{"correlation_id" => correlation_id, "user_id" => user_id},
        fn {_key, value} -> is_nil(value) end
      )
    else
      %{}
    end
  end

  defp args_user_id(args) when is_map(args),
    do: Enum.find_value(@user_id_arg_keys, &Map.get(args, &1))

  defp args_user_id(_args), do: nil
end
