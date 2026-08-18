defmodule Tymeslot.Workers.ObanQueueMonitorWorkerTest do
  # async: false — the batching test swaps the global :admin_alerts_impl so it can
  # inspect the aggregated alert payload.
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  alias Ecto.Changeset
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.ObanQueueMonitorWorker

  import ExUnit.CaptureLog
  import Tymeslot.AdminAlertsCaptureHelpers

  setup :capture_admin_alerts

  describe "perform/1" do
    test "completes successfully with no unhealthy queues" do
      assert :ok = perform_job(ObanQueueMonitorWorker, %{})
    end

    test "detects job accumulation when threshold exceeded" do
      # Create 101 available jobs (threshold is 100)
      for _i <- 1..101 do
        insert_job(%{worker: "SomeWorker", queue: "test_queue", state: "available"})
      end

      log =
        capture_log(fn ->
          assert :ok = perform_job(ObanQueueMonitorWorker, %{})
        end)

      assert log =~ "Oban queues accumulating jobs"
    end

    test "does not alert for job accumulation below threshold" do
      # Create 99 available jobs (below threshold of 100)
      for _i <- 1..99 do
        insert_job(%{worker: "SomeWorker", queue: "test_queue", state: "available"})
      end

      log =
        capture_log(fn ->
          assert :ok = perform_job(ObanQueueMonitorWorker, %{})
        end)

      refute log =~ "Oban queues accumulating jobs"
    end

    test "detects stuck available jobs" do
      # Create jobs older than 2 hours in available state
      three_hours_ago = DateTime.add(DateTime.utc_now(), -3, :hour)

      for _i <- 1..15 do
        insert_job(%{
          worker: "SomeWorker",
          queue: "stuck_queue",
          state: "available",
          inserted_at: three_hours_ago
        })
      end

      log =
        capture_log(fn ->
          assert :ok = perform_job(ObanQueueMonitorWorker, %{})
        end)

      assert log =~ "Oban queues have stuck available jobs"
    end

    test "does not alert for available jobs below stuck threshold" do
      # Create only 9 old jobs (threshold is 10)
      three_hours_ago = DateTime.add(DateTime.utc_now(), -3, :hour)

      for _i <- 1..9 do
        insert_job(%{
          worker: "SomeWorker",
          queue: "test_queue",
          state: "available",
          inserted_at: three_hours_ago
        })
      end

      log =
        capture_log(fn ->
          assert :ok = perform_job(ObanQueueMonitorWorker, %{})
        end)

      refute log =~ "stuck available jobs"
    end

    test "detects stuck retryable jobs past their scheduled time" do
      now = DateTime.utc_now()
      five_days_ago = DateTime.add(now, -5, :day)
      three_hours_ago = DateTime.add(now, -3, :hour)

      # Create retryable jobs that were inserted 5 days ago (within 7-day window)
      # and scheduled to run 3 hours ago (past their retry time)
      for _i <- 1..15 do
        insert_job(%{
          worker: "SomeWorker",
          queue: "retryable_queue",
          state: "retryable",
          inserted_at: five_days_ago,
          scheduled_at: three_hours_ago
        })
      end

      log =
        capture_log(fn ->
          assert :ok = perform_job(ObanQueueMonitorWorker, %{})
        end)

      assert log =~ "Oban queues have stuck retryable jobs"
    end

    test "does not alert for retryable jobs scheduled in the future" do
      now = DateTime.utc_now()
      three_hours_ago = DateTime.add(now, -3, :hour)
      one_hour_from_now = DateTime.add(now, 1, :hour)

      # Create retryable jobs scheduled for the future (legitimately waiting)
      for _i <- 1..15 do
        insert_job(%{
          worker: "SomeWorker",
          queue: "test_queue",
          state: "retryable",
          inserted_at: three_hours_ago,
          scheduled_at: one_hour_from_now
        })
      end

      log =
        capture_log(fn ->
          assert :ok = perform_job(ObanQueueMonitorWorker, %{})
        end)

      refute log =~ "stuck retryable jobs"
    end

    @tag :capture_log
    test "batches every unhealthy queue into one alert naming all of them" do
      # Create accumulation in 3 different queues
      for queue <- ["queue_1", "queue_2", "queue_3"] do
        for _i <- 1..101 do
          insert_job(%{worker: "SomeWorker", queue: queue, state: "available"})
        end
      end

      assert :ok = perform_job(ObanQueueMonitorWorker, %{})

      # One alert, carrying all three queues — not three separate alerts.
      assert_receive {:send_alert, :oban_jobs_accumulating, payload}
      refute_receive {:send_alert, :oban_jobs_accumulating, _other}

      assert payload.total_affected == 3

      assert payload.affected_queues
             |> Enum.map(fn {queue, _count} -> queue end)
             |> Enum.sort() == ["queue_1", "queue_2", "queue_3"]
    end

    test "ignores jobs older than 7 days for performance" do
      # Create very old jobs (8 days old)
      eight_days_ago = DateTime.add(DateTime.utc_now(), -8, :day)

      for _i <- 1..200 do
        insert_job(%{
          worker: "SomeWorker",
          queue: "old_queue",
          state: "available",
          inserted_at: eight_days_ago
        })
      end

      LogCapture.attach()

      assert :ok = perform_job(ObanQueueMonitorWorker, %{})

      # Should not alert for very old jobs (they're filtered out for
      # performance). The queue names travel as list-valued metadata, which the
      # console formatter drops entirely, so this must be asserted against the
      # captured records rather than `capture_log` output.
      refute Enum.map_join(LogCapture.drain(), " ", &LogCapture.dump/1) =~ "old_queue"
    end
  end

  # Helper to insert a job with custom attributes
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

    attrs = Map.merge(default_attrs, Map.new(attrs))

    %Oban.Job{}
    |> Changeset.change(attrs)
    |> Repo.insert!()
  end
end
