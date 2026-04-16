defmodule Tymeslot.Meetings.AttendeeNotifications.DispatcherTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration

  alias Tymeslot.Meetings.AttendeeNotifications.Dispatcher
  alias Tymeslot.Meetings.AttendeeNotifications.Worker

  setup do
    event = insert(:provider_calendar_event)
    {:ok, event: event}
  end

  describe "schedule_update/2" do
    test "enqueues a Worker job with update args", %{event: event} do
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)

      assert_enqueued(
        worker: Worker,
        args: %{
          "event_id" => event.id,
          "kind" => "provider_calendar_event",
          "action" => "update"
        }
      )
    end

    test "schedules the job ~120s in the future", %{event: event} do
      before = DateTime.utc_now()
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      [job] = all_enqueued(worker: Worker)

      # Allow a small tolerance for clock drift / test runtime.
      diff = DateTime.diff(job.scheduled_at, before)
      assert diff >= 118
      assert diff <= 125
    end

    test "a second call within the window replaces the existing job's scheduled_at", %{
      event: event
    } do
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      [job1] = all_enqueued(worker: Worker)

      :timer.sleep(10)
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      [job2] = all_enqueued(worker: Worker)

      assert job1.id == job2.id
      assert DateTime.compare(job2.scheduled_at, job1.scheduled_at) == :gt
    end
  end

  describe "schedule_delete/2" do
    test "coexists as an independent job alongside schedule_update", %{event: event} do
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      :ok = Dispatcher.schedule_delete(event.id, :provider_calendar_event)

      jobs = all_enqueued(worker: Worker)
      assert length(jobs) == 2

      actions = jobs |> Enum.map(& &1.args["action"]) |> Enum.sort()
      assert actions == ["delete", "update"]
    end

    test "uniqueness is scoped per action — second delete replaces the first", %{event: event} do
      :ok = Dispatcher.schedule_delete(event.id, :provider_calendar_event)
      [job1] = all_enqueued(worker: Worker)

      :timer.sleep(10)
      :ok = Dispatcher.schedule_delete(event.id, :provider_calendar_event)
      [job2] = all_enqueued(worker: Worker)

      assert job1.id == job2.id
    end
  end

  describe "cancel_pending/2" do
    test "removes scheduled update jobs for the event+kind", %{event: event} do
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      assert [_job] = all_enqueued(worker: Worker)

      :ok = Dispatcher.cancel_pending(event.id, :provider_calendar_event)
      assert all_enqueued(worker: Worker) == []
    end

    test "removes both update and delete jobs for the event+kind", %{event: event} do
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      :ok = Dispatcher.schedule_delete(event.id, :provider_calendar_event)

      :ok = Dispatcher.cancel_pending(event.id, :provider_calendar_event)
      assert all_enqueued(worker: Worker) == []
    end

    test "does not affect jobs for other events", %{event: event} do
      other = insert(:provider_calendar_event)

      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      :ok = Dispatcher.schedule_update(other.id, :provider_calendar_event)

      :ok = Dispatcher.cancel_pending(event.id, :provider_calendar_event)

      jobs = all_enqueued(worker: Worker)
      assert length(jobs) == 1
      assert hd(jobs).args["event_id"] == other.id
    end
  end

  describe "pending?/2" do
    test "returns false when no job is enqueued", %{event: event} do
      refute Dispatcher.pending?(event.id, :provider_calendar_event)
    end

    test "returns true once a job has been scheduled", %{event: event} do
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      assert Dispatcher.pending?(event.id, :provider_calendar_event)
    end

    test "returns false after cancel_pending removes the job", %{event: event} do
      :ok = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      :ok = Dispatcher.cancel_pending(event.id, :provider_calendar_event)
      refute Dispatcher.pending?(event.id, :provider_calendar_event)
    end
  end
end
