defmodule Tymeslot.Workers.ObanMaintenanceWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Tymeslot.Repo
  alias Tymeslot.Workers.ObanMaintenanceWorker

  describe "perform/1 - stuck job cleanup" do
    test "cleans up stuck executing jobs" do
      # Stuck in "executing" past the 12 hour discard threshold that sits
      # behind the lifeline's rescue window (see ObanRescue)
      stuck_time = DateTime.add(DateTime.utc_now(), -13, :hour)

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

    # Past the lifeline's six hour rescue window but inside the discard
    # threshold: the job belongs to the rescue, which returns it to `available`
    # to be run again, and discarding it here would take that away.
    test "leaves an executing job the lifeline has yet to rescue" do
      rescuable_time = DateTime.add(DateTime.utc_now(), -7, :hour)

      {:ok, job} =
        Repo.insert(%Oban.Job{
          state: "executing",
          attempted_at: rescuable_time,
          worker: "SomeWorker",
          queue: "default",
          args: %{},
          errors: [],
          inserted_at: rescuable_time
        })

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.stuck_cleaned == 0

      # Job should remain in executing state
      updated_job = Repo.get(Oban.Job, job.id)
      assert updated_job.state == "executing"
    end

    test "cleans up multiple stuck jobs" do
      stuck_time = DateTime.add(DateTime.utc_now(), -14, :hour)

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

    test "handles empty job table gracefully" do
      # Delete all jobs
      Repo.delete_all(Oban.Job)

      assert {:ok, result} = perform_job(ObanMaintenanceWorker, %{})
      assert result.stuck_cleaned == 0
    end

    test "leaves scheduling to the crontab rather than enqueuing itself" do
      assert {:ok, _result} = perform_job(ObanMaintenanceWorker, %{})

      refute_enqueued(worker: ObanMaintenanceWorker)
    end
  end

  describe "discard_stuck_jobs/1" do
    # The scan and the discard are two statements: a job can finish between
    # them, and the guarded discard then leaves it alone.
    test "leaves a job that finished after the scan without logging an error" do
      stuck_time = DateTime.add(DateTime.utc_now(), -13, :hour)

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

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])

      {discarded, log} =
        with_log(fn -> ObanMaintenanceWorker.discard_stuck_jobs([job]) end)

      assert discarded == []
      assert Repo.get(Oban.Job, job.id).state == "completed"
      # A routine race, logged below the suite's level, never as a failure.
      refute log =~ "Failed to clean stuck job"
    end
  end

  describe "perform/1 - input validation" do
    test "accepts unknown job arguments (forward compatibility)" do
      # Job with extra fields from future version
      assert {:ok, _cleanup_result} =
               perform_job(ObanMaintenanceWorker, %{"future_option" => true})
    end
  end
end
