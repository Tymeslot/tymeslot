defmodule Tymeslot.DatabaseQueries.ObanJobQueries do
  @moduledoc """
  Query interface for Oban job-related database operations.
  """
  import Ecto.Query, warn: false
  alias Ecto.Changeset
  alias Tymeslot.Repo

  @doc """
  Counts maintenance worker jobs in active states.
  """
  @spec count_active_maintenance_jobs(String.t()) :: non_neg_integer()
  def count_active_maintenance_jobs(worker_name) do
    query =
      from(j in Oban.Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "executing"],
        select: count(j.id)
      )

    Repo.one(query)
  end

  @doc """
  Gets all stuck executing jobs older than the given threshold.
  """
  @spec get_stuck_executing_jobs(DateTime.t()) :: [Oban.Job.t()]
  def get_stuck_executing_jobs(threshold_datetime) do
    query =
      from(j in Oban.Job,
        where: j.state == "executing",
        where: j.attempted_at < ^threshold_datetime,
        select: j
      )

    Repo.all(query)
  end

  @doc """
  Updates a job to discarded state with error information.
  """
  @spec update_job_to_discarded(Oban.Job.t(), map()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def update_job_to_discarded(job, error_info) do
    job
    |> Changeset.change(%{
      state: "discarded",
      discarded_at: DateTime.utc_now(),
      errors: job.errors ++ [error_info]
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
      from(j in Oban.Job,
        where: j.state in ["completed", "discarded", "cancelled"],
        where: j.inserted_at < ^cutoff_date
      )
    )
  end
end
