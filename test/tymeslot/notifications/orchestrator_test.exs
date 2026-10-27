defmodule Tymeslot.Notifications.OrchestratorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :notifications

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Workers.EmailWorker

  describe "schedule_reminder_notifications/1" do
    test "schedules a job for each reminder interval" do
      meeting =
        insert(:meeting,
          start_time: DateTime.add(DateTime.utc_now(), 2, :hour),
          reminders: [
            %{"value" => 30, "unit" => "minutes"},
            %{"value" => 1, "unit" => "hours"}
          ]
        )

      assert :ok = Orchestrator.schedule_reminder_notifications(meeting)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_reminder_emails",
          "meeting_id" => meeting.id,
          "reminder_value" => 30,
          "reminder_unit" => "minutes"
        }
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_reminder_emails",
          "meeting_id" => meeting.id,
          "reminder_value" => 1,
          "reminder_unit" => "hours"
        }
      )

      assert length(all_enqueued(worker: EmailWorker)) == 2
    end

    test "schedules reminders at the correct absolute time" do
      # Use a date in the future to ensure the reminder is scheduled
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      meeting =
        insert(:meeting,
          start_time: start_time,
          end_time: DateTime.add(start_time, 60, :minute),
          reminders: [%{value: 1, unit: "hours"}]
        )

      Orchestrator.schedule_reminder_notifications(meeting)

      # Assert the job is scheduled exactly 1 hour before start_time
      expected_time = DateTime.add(start_time, -1, :hour)

      assert_enqueued(
        worker: EmailWorker,
        scheduled_at: expected_time,
        args: %{
          "action" => "send_reminder_emails",
          "meeting_id" => meeting.id,
          "reminder_value" => 1,
          "reminder_unit" => "hours"
        }
      )
    end

    # Booked for 25 h away with a 24 h reminder, then moved to 23 h away: the
    # 24 h reminder is now too late to send, and the job pinned to the old
    # time must go rather than fire with "in 1 day" for a meeting 23 h off.
    test "a meeting moved closer loses a reminder that is now too late" do
      now = DateTime.utc_now()

      meeting =
        insert(:meeting,
          start_time: DateTime.add(now, 25, :hour),
          end_time: DateTime.add(now, 26, :hour),
          reminders: [%{"value" => 24, "unit" => "hours"}, %{"value" => 1, "unit" => "hours"}]
        )

      assert :ok = Orchestrator.schedule_reminder_notifications(meeting)
      assert length(all_enqueued(worker: EmailWorker)) == 2

      moved = %{
        meeting
        | start_time: DateTime.add(now, 23, :hour),
          end_time: DateTime.add(now, 24, :hour)
      }

      assert :ok = Orchestrator.schedule_reminder_notifications(moved, replace: true)

      assert [%Oban.Job{args: %{"reminder_value" => 1, "reminder_unit" => "hours"}} = job] =
               all_enqueued(worker: EmailWorker)

      assert DateTime.compare(job.scheduled_at, DateTime.add(now, 22, :hour)) in [:eq, :gt]
    end

    test "leaves another meeting's reminders alone" do
      start_time = DateTime.add(DateTime.utc_now(), 2, :day)
      slot = [start_time: start_time, end_time: DateTime.add(start_time, 1, :hour)]
      reminders = [%{"value" => 1, "unit" => "hours"}]
      other = insert(:meeting, [reminders: reminders] ++ slot)
      meeting = insert(:meeting, [reminders: reminders] ++ slot)

      assert :ok = Orchestrator.schedule_reminder_notifications(other)
      assert :ok = Orchestrator.schedule_reminder_notifications(meeting, replace: true)

      assert all_enqueued(worker: EmailWorker) |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort() ==
               Enum.sort([other.id, meeting.id])
    end

    test "does not schedule reminders when list is empty" do
      meeting =
        insert(:meeting,
          start_time: DateTime.add(DateTime.utc_now(), 2, :hour),
          reminders: []
        )

      assert {:ok, :reminder_not_scheduled} =
               Orchestrator.schedule_reminder_notifications(meeting)

      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "schedule_meeting_notifications/1" do
    # A meeting missing what its emails need is checked on its own fields and
    # gets nothing queued; the booking itself is not refused.
    test "a meeting without an attendee address queues no confirmation and no reminder" do
      start_time = DateTime.add(DateTime.utc_now(), 2, :day)

      meeting =
        insert(:meeting,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour),
          attendee_email: nil,
          reminders: [%{"value" => 1, "unit" => "hours"}]
        )

      assert {:ok, :notifications_scheduled} =
               Orchestrator.schedule_meeting_notifications(meeting)

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "a complete meeting queues its confirmation and its reminder" do
      start_time = DateTime.add(DateTime.utc_now(), 2, :day)

      meeting =
        insert(:meeting,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour),
          reminders: [%{"value" => 1, "unit" => "hours"}]
        )

      assert {:ok, :notifications_scheduled} =
               Orchestrator.schedule_meeting_notifications(meeting)

      assert Enum.sort(Enum.map(all_enqueued(worker: EmailWorker), & &1.args["action"])) ==
               ["send_confirmation_emails", "send_reminder_emails"]
    end
  end
end
