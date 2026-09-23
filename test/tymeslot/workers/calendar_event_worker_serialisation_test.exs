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
      running = running_job(meeting.id, "update", started: -1)

      assert {:snooze, seconds} =
               CalendarEventWorker.perform(job(running.id + 1, meeting.id, "update"))

      assert seconds > 0
    end

    test "waits for any action, not only another update" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "create", started: -1)

      assert {:snooze, _seconds} =
               CalendarEventWorker.perform(job(running.id + 1, meeting.id, "update"))
    end

    # Enqueue order is not start order: a retry runs again under its old id,
    # and a lower priority or a longer snooze lets a newer job go first.
    test "waits for a newer job that started first" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "delete", started: -1)

      assert {:snooze, _seconds} =
               CalendarEventWorker.perform(job(running.id - 1, meeting.id, "update"))
    end

    test "does not wait for a write to a different meeting" do
      %{meeting: meeting} = setup_calendar_scenario()
      %{meeting: other} = setup_calendar_scenario()
      running = running_job(other.id, "update", started: -1)
      expect_calendar_update_success()

      assert :ok = CalendarEventWorker.perform(job(running.id + 1, meeting.id, "update"))
    end

    test "does not wait for an older job that started after it" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "update", started: 1)
      expect_calendar_update_success()

      assert :ok = CalendarEventWorker.perform(job(running.id + 1, meeting.id, "update"))
    end

    # Two jobs fetched in the same instant: the id decides, so exactly one waits.
    test "breaks a tie in start time by enqueue order" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "update", started: 0)

      assert {:snooze, _seconds} =
               CalendarEventWorker.perform(job(running.id + 1, meeting.id, "update"))

      expect_calendar_update_success()
      assert :ok = CalendarEventWorker.perform(job(running.id - 1, meeting.id, "update"))
    end

    test "gives up waiting once the budget is spent and takes its chances" do
      %{meeting: meeting} = setup_calendar_scenario()
      running = running_job(meeting.id, "update", started: -1)
      expect_calendar_update_success()

      spent = %{job(running.id + 1, meeting.id, "update") | meta: %{"snoozed" => 99}}

      assert :ok = CalendarEventWorker.perform(spent)
    end
  end

  # Every job here is judged against the same instant, and a running job's
  # `started:` offset in seconds places its start before or after it.
  @now ~U[2026-01-01 12:00:00.000000Z]

  defp job(id, meeting_id, action) do
    %Oban.Job{
      id: id,
      attempt: 1,
      max_attempts: 5,
      meta: %{},
      args: %{"action" => action, "meeting_id" => meeting_id},
      worker: inspect(CalendarEventWorker),
      queue: "calendar_events",
      state: "executing",
      attempted_at: @now
    }
  end

  defp running_job(meeting_id, action, started: offset) do
    Repo.insert!(%Oban.Job{
      state: "executing",
      queue: "calendar_events",
      worker: inspect(CalendarEventWorker),
      args: %{"action" => action, "meeting_id" => meeting_id},
      attempt: 1,
      max_attempts: 5,
      attempted_at: DateTime.add(@now, offset, :second)
    })
  end
end
