defmodule Tymeslot.Jobs.ObanJobQueriesTest do
  @moduledoc """
  Verifies that the hand-rolled "pending job" queries agree with the workers'
  Oban `unique: [states: ...]` guards. In particular a `suspended` job has not
  reached a terminal state and must be treated as pending, so the manual
  duplicate-prevention checks do not allow a double-enqueue.
  """
  use Tymeslot.DataCase, async: true

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

    test "counts available, scheduled, executing and suspended jobs together" do
      for state <- ~w(available scheduled executing suspended) do
        insert_job(%{worker: @worker, state: state})
      end

      assert ObanJobQueries.count_active_maintenance_jobs(@worker) == 4
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
