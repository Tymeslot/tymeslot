defmodule Tymeslot.CalendarGrid.ScheduledDeleteQueries do
  @moduledoc "Database access for `Tymeslot.CalendarGrid.ScheduledDelete`."

  import Ecto.Query

  alias Tymeslot.Clock
  alias Tymeslot.Repo

  @worker "Tymeslot.Workers.CalendarEventDeleteWorker"

  @doc """
  Cancels the scheduled delete `job_id` of `user_id` in one statement, but
  only while it is still waiting: a job already running or finished is left
  alone. True when it was cancelled.
  """
  @spec cancel_waiting(pos_integer(), pos_integer()) :: boolean()
  def cancel_waiting(job_id, user_id) do
    query =
      from(job in Oban.Job,
        where:
          job.id == ^job_id and job.worker == @worker and
            job.state in ["scheduled", "available"] and
            fragment("(?->>'user_id')::bigint", job.args) == ^user_id
      )

    {count, _rows} =
      Repo.update_all(query, set: [state: "cancelled", cancelled_at: Clock.utc_now()])

    count == 1
  end
end
