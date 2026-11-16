defmodule Tymeslot.CalendarGrid.ScheduledDeleteQueries do
  @moduledoc "Database access for `Tymeslot.CalendarGrid.ScheduledDelete`."

  import Ecto.Query

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
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

  @doc """
  The state of the delete `job_id` of `user_id`, `nil` when there is no such
  delete.
  """
  @spec state(pos_integer(), pos_integer()) :: String.t() | nil
  def state(job_id, user_id) do
    query =
      from(job in Oban.Job,
        where:
          job.id == ^job_id and job.worker == @worker and
            fragment("(?->>'user_id')::bigint", job.args) == ^user_id,
        select: job.state
      )

    Repo.one(query)
  end

  @doc """
  The jobs of `user_id`'s deletes that have not finished: waiting out their
  undo window, due, running, or waiting for a retry. Oldest first.
  """
  @spec waiting(pos_integer()) :: [Oban.Job.t()]
  def waiting(user_id) do
    query =
      from(job in Oban.Job,
        where:
          job.worker == @worker and
            job.state in ["scheduled", "available", "executing", "retryable"] and
            fragment("(?->>'user_id')::bigint", job.args) == ^user_id,
        order_by: [asc: job.id]
      )

    Repo.all(query)
  end

  @doc """
  Whether any cached row of the series at `address` (see
  `Tymeslot.CalendarGrid.Occurrence.series_address/1`) remains for the
  integration.
  """
  @spec series_row_exists?(pos_integer(), {:master | :resource, String.t()}) :: boolean()
  def series_row_exists?(integration_id, {:master, master_id}) do
    ProviderCalendarEventSchema
    |> where(
      [e],
      e.calendar_integration_id == ^integration_id and
        (e.recurring_event_id == ^master_id or e.provider_event_id == ^master_id)
    )
    |> Repo.exists?()
  end

  def series_row_exists?(integration_id, {:resource, href}) do
    ProviderCalendarEventSchema
    |> where(
      [e],
      e.calendar_integration_id == ^integration_id and e.provider_event_id == ^href
    )
    |> Repo.exists?()
  end
end
