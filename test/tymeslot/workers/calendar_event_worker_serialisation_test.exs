defmodule Tymeslot.Workers.CalendarEventWorkerSerialisationTest do
  @moduledoc """
  Two writes to one calendar event never go out at the same time.

  The server settles a collision by refusing the second conditional PUT, which
  loses whatever that write was carrying — the case this guards is a video link
  attached while the approval's update is still on the wire.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Mox
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  describe "perform/1 behind another write" do
    test "waits while an earlier write to the same meeting is in flight" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "update")

      assert {:snooze, seconds} =
               CalendarEventWorker.perform(job(running.id + 1, meeting.id, "update"))

      assert seconds > 0
    end

    test "waits for any action, not only another update" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "create")

      assert {:snooze, _seconds} =
               CalendarEventWorker.perform(job(running.id + 1, meeting.id, "update"))
    end

    test "does not wait for a write to a different meeting" do
      %{meeting: meeting} = setup_calendar_scenario()
      %{meeting: other} = setup_calendar_scenario()
      running = running_job(other.id, "update")
      expect_calendar_update_success()

      assert :ok = CalendarEventWorker.perform(job(running.id + 1, meeting.id, "update"))
    end

    test "does not wait for a job that was enqueued after it" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "update")
      expect_calendar_update_success()

      assert :ok = CalendarEventWorker.perform(job(running.id - 1, meeting.id, "update"))
    end

    test "gives up waiting once the budget is spent and takes its chances" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "update")
      expect_calendar_update_success()

      spent = %{job(running.id + 1, meeting.id, "update") | meta: %{"snoozed" => 99}}

      assert :ok = CalendarEventWorker.perform(spent)
    end
  end

  defp job(id, meeting_id, action) do
    %Oban.Job{
      id: id,
      attempt: 1,
      max_attempts: 5,
      meta: %{},
      args: %{"action" => action, "meeting_id" => meeting_id},
      worker: inspect(CalendarEventWorker),
      queue: "calendar_events",
      state: "executing"
    }
  end

  defp running_job(meeting_id, action) do
    Repo.insert!(%Oban.Job{
      state: "executing",
      queue: "calendar_events",
      worker: inspect(CalendarEventWorker),
      args: %{"action" => action, "meeting_id" => meeting_id},
      attempt: 1,
      max_attempts: 5,
      attempted_at: DateTime.utc_now()
    })
  end
end
