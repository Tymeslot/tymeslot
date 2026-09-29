defmodule Tymeslot.Workers.ObanMaintenanceWorkerAlertTest do
  # async: false: the admin alert implementation is global application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :infrastructure

  import Tymeslot.AdminAlertsCaptureHelpers

  alias Tymeslot.Repo
  alias Tymeslot.Workers.ObanMaintenanceWorker

  setup :capture_admin_alerts

  defp insert_stuck_job(worker, queue) do
    stuck_time = DateTime.add(DateTime.utc_now(), -13, :hour)

    Repo.insert!(%Oban.Job{
      state: "executing",
      attempted_at: stuck_time,
      worker: worker,
      queue: queue,
      args: %{},
      errors: [],
      inserted_at: stuck_time
    })
  end

  # Moving a row straight to `discarded` emits no job telemetry, so nothing
  # else would ever tell the operator that the work was dropped.
  test "discarding two stuck jobs raises one alert naming both workers" do
    insert_stuck_job("Tymeslot.Workers.EmailWorker", "emails")
    insert_stuck_job("Tymeslot.Workers.VideoRoomWorker", "video")

    assert {:ok, %{stuck_cleaned: 2}} = perform_job(ObanMaintenanceWorker, %{})

    assert_receive {:send_alert, :oban_jobs_force_discarded, payload}
    assert payload.count == 2
    assert payload.discarded_by == inspect(ObanMaintenanceWorker)
    assert payload.jobs =~ "Tymeslot.Workers.EmailWorker (emails): 1"
    assert payload.jobs =~ "Tymeslot.Workers.VideoRoomWorker (video): 1"
    refute_receive {:send_alert, _type, _payload}
  end

  test "a sweep that discards nothing raises no alert" do
    assert {:ok, %{stuck_cleaned: 0}} = perform_job(ObanMaintenanceWorker, %{})
    refute_receive {:send_alert, _type, _payload}
  end
end
