defmodule Tymeslot.Workers.ObanMaintenanceWorkerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  alias Tymeslot.Repo
  alias Tymeslot.Workers.ObanMaintenanceWorker
  import Ecto.Query

  describe "perform/1 - stuck job cleanup" do
    test "cleans up stuck executing jobs" do
      # Create a job that is stuck in "executing" state for 5 hours
      stuck_time = DateTime.add(DateTime.utc_now(), -5, :hour)

      {:ok, job} =
        Repo.insert(%Oban.Job{
          state: "executing",
          attempted_at: stuck_time,
          worker: "SomeWorker",
          queue: "default",
          args: %{},
          errors: [],
          inserted_at: stuck_time
        })

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.stuck_cleaned == 1

      updated_job = Repo.get(Oban.Job, job.id)
      assert updated_job.state == "discarded"
      assert length(updated_job.errors) == 1
      assert Enum.at(updated_job.errors, 0)["kind"] == "stuck_job_cleanup"
    end

    test "does not clean up recent executing jobs" do
      # Job that's only been executing for 1 hour (threshold is 4 hours)
      recent_time = DateTime.add(DateTime.utc_now(), -1, :hour)

      {:ok, job} =
        Repo.insert(%Oban.Job{
          state: "executing",
          attempted_at: recent_time,
          worker: "SomeWorker",
          queue: "default",
          args: %{},
          errors: [],
          inserted_at: recent_time
        })

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.stuck_cleaned == 0

      # Job should remain in executing state
      updated_job = Repo.get(Oban.Job, job.id)
      assert updated_job.state == "executing"
    end

    test "cleans up multiple stuck jobs" do
      stuck_time = DateTime.add(DateTime.utc_now(), -6, :hour)

      # Create 3 stuck jobs
      for worker_num <- 1..3 do
        Repo.insert!(%Oban.Job{
          state: "executing",
          attempted_at: stuck_time,
          worker: "Worker#{worker_num}",
          queue: "default",
          args: %{},
          errors: [],
          inserted_at: stuck_time
        })
      end

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.stuck_cleaned == 3
    end

    test "handles jobs with nil attempted_at gracefully" do
      # Edge case: job in executing state but missing attempted_at
      Repo.insert!(%Oban.Job{
        state: "executing",
        attempted_at: nil,
        worker: "BrokenWorker",
        queue: "default",
        args: %{},
        errors: [],
        inserted_at: DateTime.utc_now()
      })

      # Should not crash
      assert {:ok, _cleaned_result} = perform_job(ObanMaintenanceWorker, %{})
    end
  end

  describe "perform/1 - old job deletion" do
    test "deletes old jobs in terminal states" do
      old_date = DateTime.add(DateTime.utc_now(), -95, :day)

      # Old completed job (should be deleted)
      Repo.insert!(%Oban.Job{
        state: "completed",
        inserted_at: old_date,
        worker: "SomeWorker",
        queue: "default",
        args: %{}
      })

      # Recent completed job (should be kept)
      Repo.insert!(%Oban.Job{
        state: "completed",
        inserted_at: DateTime.utc_now(),
        worker: "SomeWorker",
        queue: "default",
        args: %{}
      })

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.old_deleted == 1

      # Check remaining jobs (recent completed + maintenance job that was scheduled)
      remaining_count = Repo.one(from j in Oban.Job, select: count(j.id))
      assert remaining_count >= 1
    end

    test "deletes old discarded jobs" do
      old_date = DateTime.add(DateTime.utc_now(), -100, :day)

      Repo.insert!(%Oban.Job{
        state: "discarded",
        inserted_at: old_date,
        worker: "FailedWorker",
        queue: "default",
        args: %{}
      })

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.old_deleted == 1
    end

    test "deletes old cancelled jobs" do
      old_date = DateTime.add(DateTime.utc_now(), -100, :day)

      Repo.insert!(%Oban.Job{
        state: "cancelled",
        inserted_at: old_date,
        worker: "CancelledWorker",
        queue: "default",
        args: %{}
      })

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.old_deleted == 1
    end

    test "does not delete pending or executing jobs" do
      old_date = DateTime.add(DateTime.utc_now(), -100, :day)

      # Old but still pending
      Repo.insert!(%Oban.Job{
        state: "available",
        inserted_at: old_date,
        worker: "PendingWorker",
        queue: "default",
        args: %{}
      })

      # Old but still executing
      Repo.insert!(%Oban.Job{
        state: "executing",
        inserted_at: old_date,
        attempted_at: old_date,
        worker: "ExecutingWorker",
        queue: "default",
        args: %{},
        errors: []
      })

      initial_count = Repo.one(from j in Oban.Job, select: count(j.id))

      assert {:ok, _cleanup_result} = perform_job(ObanMaintenanceWorker, %{})

      final_count = Repo.one(from j in Oban.Job, select: count(j.id))

      # Should have added the scheduled maintenance job
      assert final_count >= initial_count
    end

    test "handles empty job table gracefully" do
      # Delete all jobs
      Repo.delete_all(Oban.Job)

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.stuck_cleaned == 0
      assert result.old_deleted == 0
    end

    test "schedules next run after completion" do
      assert {:ok, _result} = perform_job(ObanMaintenanceWorker, %{})

      assert_enqueued(
        worker: ObanMaintenanceWorker,
        args: %{"action" => "maintenance"}
      )
    end
  end

  describe "perform/1 - input validation" do
    test "accepts unknown job arguments (forward compatibility)" do
      # Job with extra fields from future version
      assert {:ok, _cleanup_result} = perform_job(ObanMaintenanceWorker, %{"future_option" => true})
    end

    test "handles empty args" do
      assert {:ok, _cleanup_result} = perform_job(ObanMaintenanceWorker, %{})
    end
  end

  describe "start_if_not_scheduled/0" do
    test "schedules a job if none exists" do
      ObanMaintenanceWorker.start_if_not_scheduled()

      assert_enqueued(
        worker: ObanMaintenanceWorker,
        args: %{"action" => "maintenance"}
      )
    end

    test "does not schedule a job if one already exists" do
      # First one
      ObanMaintenanceWorker.start_if_not_scheduled()

      initial_count =
        Repo.one(
          from j in Oban.Job,
            where: j.worker == "Tymeslot.Workers.ObanMaintenanceWorker",
            select: count(j.id)
        )

      assert initial_count == 1

      # Second call
      ObanMaintenanceWorker.start_if_not_scheduled()

      final_count =
        Repo.one(
          from j in Oban.Job,
            where: j.worker == "Tymeslot.Workers.ObanMaintenanceWorker",
            select: count(j.id)
        )

      assert final_count == 1
    end
  end
end
