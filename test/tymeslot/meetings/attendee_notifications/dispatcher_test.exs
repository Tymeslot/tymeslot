defmodule Tymeslot.Meetings.AttendeeNotifications.DispatcherTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :meetings
  @moduletag :notifications

  alias Tymeslot.Meetings.AttendeeNotifications.Dispatcher
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Repo

  setup do
    event = insert(:provider_calendar_event)
    {:ok, event: event}
  end

  describe "schedule_update/2" do
    test "enqueues a Worker job with update args", %{event: event} do
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)

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
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      [job] = all_enqueued(worker: Worker)

      # Allow a small tolerance for clock drift / test runtime.
      diff = DateTime.diff(job.scheduled_at, before)
      assert diff >= 118
      assert diff <= 125
    end

    test "a second call within the window replaces the existing job", %{
      event: event
    } do
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      [job1] = all_enqueued(worker: Worker)

      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      [job2] = all_enqueued(worker: Worker)

      assert job1.id == job2.id
    end
  end

  describe "cancel_pending/3" do
    test "removes scheduled update jobs for the event+kind", %{event: event} do
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      assert [_job] = all_enqueued(worker: Worker)

      {:ok, :cancelled} =
        Dispatcher.cancel_pending(event.id, :provider_calendar_event, due_at(event))

      assert all_enqueued(worker: Worker) == []
    end

    # Delete jobs are no longer enqueued, but ones enqueued before are still
    # in the queue after a deploy.
    test "removes both update and legacy delete jobs for the event+kind", %{event: event} do
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)

      {:ok, _job} =
        %{"event_id" => event.id, "kind" => "provider_calendar_event", "action" => "delete"}
        |> Worker.new(schedule_in: 120)
        |> Oban.insert()

      assert length(all_enqueued(worker: Worker)) == 2

      {:ok, :cancelled} =
        Dispatcher.cancel_pending(event.id, :provider_calendar_event, due_at(event))

      assert all_enqueued(worker: Worker) == []
    end

    test "says the update was sent when the hold ran before the cancel", %{event: event} do
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      due_at = due_at(event)
      now = DateTime.utc_now()
      Repo.update_all(Oban.Job, set: [state: "completed", attempted_at: now, completed_at: now])

      assert Dispatcher.cancel_pending(event.id, :provider_calendar_event, due_at) == {:ok, :sent}
    end

    test "counts a hold that is retrying as sent, since it will still go out", %{event: event} do
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      due_at = due_at(event)

      # A retry is scheduled later than the hold was due.
      Repo.update_all(Oban.Job,
        set: [
          state: "retryable",
          attempted_at: DateTime.utc_now(),
          scheduled_at: DateTime.add(due_at, 30)
        ]
      )

      assert Dispatcher.cancel_pending(event.id, :provider_calendar_event, due_at) == {:ok, :sent}
    end

    test "says nothing was waiting when no update ran or waits", %{event: event} do
      assert Dispatcher.cancel_pending(event.id, :provider_calendar_event, DateTime.utc_now()) ==
               {:ok, :none}
    end

    # Told at t0 (out at t0+2m), told again at t0+5m, that second hold
    # cancelled in another tab: a Cancel for it still finds the first job,
    # which went out before the hold began and told nobody about it.
    test "an update sent before the hold is not the hold going out", %{event: event} do
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      two_minutes_ago = DateTime.add(DateTime.utc_now(), -120)

      Repo.update_all(Oban.Job,
        set: [
          state: "completed",
          scheduled_at: DateTime.add(two_minutes_ago, -1),
          attempted_at: two_minutes_ago,
          completed_at: two_minutes_ago
        ]
      )

      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      second_hold = due_at(event)

      {:ok, :cancelled} =
        Dispatcher.cancel_pending(event.id, :provider_calendar_event, second_hold)

      assert Dispatcher.cancel_pending(event.id, :provider_calendar_event, second_hold) ==
               {:ok, :none}
    end

    test "does not affect jobs for other events", %{event: event} do
      other = insert(:provider_calendar_event)

      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      {:ok, :scheduled} = Dispatcher.schedule_update(other.id, :provider_calendar_event)

      {:ok, :cancelled} =
        Dispatcher.cancel_pending(event.id, :provider_calendar_event, due_at(event))

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
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)
      assert Dispatcher.pending?(event.id, :provider_calendar_event)
    end

    test "returns false after cancel_pending removes the job", %{event: event} do
      {:ok, :scheduled} = Dispatcher.schedule_update(event.id, :provider_calendar_event)

      {:ok, :cancelled} =
        Dispatcher.cancel_pending(event.id, :provider_calendar_event, due_at(event))

      refute Dispatcher.pending?(event.id, :provider_calendar_event)
    end
  end

  defp due_at(event), do: Dispatcher.pending_due_at(event.id, :provider_calendar_event)
end
