defmodule Tymeslot.Jobs.ObanJobQueriesTest do
  @moduledoc """
  Verifies that the hand-rolled "pending job" queries agree with the workers'
  Oban `unique: [states: ...]` guards. In particular a `suspended` job has not
  reached a terminal state and must be treated as pending, so the manual
  duplicate-prevention checks do not allow a double-enqueue.
  """
  use Tymeslot.DataCase, async: true

  import Ecto.Query

  @moduletag :workers
  @moduletag :queries

  alias Ecto.Changeset
  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Repo

  @worker "Tymeslot.Workers.SomeMaintenanceWorker"

  describe "count_active_maintenance_jobs/1" do
    test "counts a suspended job as active" do
      insert_job(%{worker: @worker, state: "suspended"})

      assert ObanJobQueries.count_active_maintenance_jobs(@worker) == 1
    end

    # A run waiting to retry has not finished either; counting it as absent
    # let a second run be scheduled behind it.
    test "counts every incomplete job, retryable included" do
      for state <- ~w(available scheduled executing retryable suspended) do
        insert_job(%{worker: @worker, state: state})
      end

      assert ObanJobQueries.count_active_maintenance_jobs(@worker) == 5
    end

    test "ignores terminal jobs" do
      for state <- ~w(completed discarded cancelled) do
        insert_job(%{worker: @worker, state: state})
      end

      assert ObanJobQueries.count_active_maintenance_jobs(@worker) == 0
    end
  end

  describe "user_ids_with_pending_jobs_for_actions/2" do
    test "treats a suspended job as pending" do
      insert_job(%{
        worker: @worker,
        state: "suspended",
        args: %{"action" => "notify", "user_id" => 42}
      })

      assert ObanJobQueries.user_ids_with_pending_jobs_for_actions(@worker, ["notify"]) == [42]
    end

    test "does not return users whose only job is terminal" do
      insert_job(%{
        worker: @worker,
        state: "completed",
        args: %{"action" => "notify", "user_id" => 7}
      })

      assert ObanJobQueries.user_ids_with_pending_jobs_for_actions(@worker, ["notify"]) == []
    end
  end

  describe "delete_meeting_jobs/2" do
    test "deletes a pending job for the meeting" do
      insert_job(%{
        worker: @worker,
        state: "scheduled",
        args: %{"meeting_id" => "meeting-1"}
      })

      assert {1, nil} = ObanJobQueries.delete_meeting_jobs(@worker, "meeting-1")
    end

    test "ignores a job in a terminal state" do
      insert_job(%{
        worker: @worker,
        state: "completed",
        args: %{"meeting_id" => "meeting-1"}
      })

      assert {0, nil} = ObanJobQueries.delete_meeting_jobs(@worker, "meeting-1")
    end
  end

  describe "update_job_to_discarded/2" do
    test "discards a job still executing and appends the error" do
      job = insert_job(%{state: "executing", errors: [%{"error" => "earlier"}]})

      assert {:ok, :discarded} =
               ObanJobQueries.update_job_to_discarded(job, %{error: "stuck", attempt: 1})

      assert %{state: "discarded", discarded_at: %DateTime{}, errors: errors} = Repo.reload!(job)
      assert [%{"error" => "earlier"}, %{"error" => "stuck", "attempt" => 1}] = errors
    end

    # The maintenance worker read the job as stuck; it finished before the
    # discard landed, and must not be marked as dropped.
    test "leaves a job that finished after it was read" do
      stale = insert_job(%{state: "executing"})
      Repo.update_all(from(j in Oban.Job, where: j.id == ^stale.id), set: [state: "completed"])

      assert {:error, :no_longer_executing} =
               ObanJobQueries.update_job_to_discarded(stale, %{error: "stuck"})

      assert %{state: "completed", errors: []} = Repo.reload!(stale)
    end
  end

  defp insert_job(attrs) do
    default_attrs = %{
      worker: "DefaultWorker",
      queue: "default",
      state: "available",
      args: %{},
      attempt: 0,
      max_attempts: 20,
      inserted_at: DateTime.utc_now(),
      scheduled_at: DateTime.utc_now()
    }

    %Oban.Job{}
    |> Changeset.change(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end
end
