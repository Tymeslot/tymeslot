defmodule Tymeslot.Bookings.CalendarJobsTest do
  @moduledoc """
  Tests for `Tymeslot.Bookings.CalendarJobs.schedule_job/2`. This module
  is the single entry point for enqueueing CalendarEventWorker jobs from
  the booking subsystem; its dedup contract — "a duplicate insert
  returns `{:ok, :already_scheduled}` instead of an error" — is relied
  on by both Create and Reschedule to tolerate retries without surfacing
  spurious failures.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker

  describe "schedule_job/2" do
    test "enqueues a CalendarEventWorker job with create priority" do
      meeting = insert(:meeting)

      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting, "create")

      assert [job] = all_enqueued(worker: CalendarEventWorker)
      assert job.args == %{"action" => "create", "meeting_id" => meeting.id}
      assert job.queue == "calendar_events"
      assert job.priority == 0
    end

    test "enqueues a CalendarEventWorker job with update priority" do
      meeting = insert(:meeting)

      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting, "update")

      assert [job] = all_enqueued(worker: CalendarEventWorker)
      assert job.args["action"] == "update"
      assert job.priority == 2
    end

    test "schedules separate jobs for different meetings" do
      meeting_a = insert(:meeting)
      meeting_b = insert(:meeting)

      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting_a, "create")
      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting_b, "create")

      assert length(all_enqueued(worker: CalendarEventWorker)) == 2
    end

    test "returns :already_scheduled when the same job is inserted twice" do
      meeting = insert(:meeting)

      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting, "create")
      assert {:ok, :already_scheduled} = CalendarJobs.schedule_job(meeting, "create")
    end

    # An update carries the meeting as it stands when the job runs. One that is
    # already executing read it before the change that prompted this call, so
    # collapsing into it drops that change: this is how the video link goes
    # missing from an approved booking's calendar entry.
    test "still enqueues an update while another update is executing" do
      meeting = insert(:meeting)

      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting, "update")
      start_running(meeting, "update")

      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting, "update")
    end

    test "collapses an update into one that has not started yet" do
      meeting = insert(:meeting)

      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting, "update")
      assert {:ok, :already_scheduled} = CalendarJobs.schedule_job(meeting, "update")
    end

    # A create and a delete do not carry state that can go stale: whatever the
    # running job writes is what the meeting says, so a second one is waste.
    test "collapses a create into one that is executing" do
      meeting = insert(:meeting)

      assert {:ok, :scheduled} = CalendarJobs.schedule_job(meeting, "create")
      start_running(meeting, "create")

      assert {:ok, :already_scheduled} = CalendarJobs.schedule_job(meeting, "create")
    end
  end

  describe "CalendarEventScheduler.schedule_calendar_update/1" do
    # The path `Meetings.VideoRooms` takes once a room exists: the approval's
    # own update is in flight, and this one carries the link it never saw.
    test "enqueues while another update for the same meeting is executing" do
      meeting = insert(:meeting)

      assert {:ok, _job} = CalendarEventScheduler.schedule_calendar_update(meeting.id)
      start_running(meeting, "update")

      assert {:ok, job} = CalendarEventScheduler.schedule_calendar_update(meeting.id)
      refute job.conflict?
    end

    test "a deletion still collapses into one that is executing" do
      meeting = insert(:meeting)

      assert {:ok, _job} = CalendarEventScheduler.schedule_calendar_deletion(meeting.id)
      start_running(meeting, "delete")

      assert {:ok, job} = CalendarEventScheduler.schedule_calendar_deletion(meeting.id)
      assert job.conflict?
    end
  end

  describe "CalendarEventScheduler.schedule_calendar_replacement/2" do
    # A running replacement may already have read the meeting back on Teams
    # and chosen to update the event; a reschedule away from Teams since then
    # needs a replacement of its own.
    test "enqueues while a replacement of the same event is executing" do
      meeting = insert(:meeting)

      assert {:ok, _job} =
               CalendarEventScheduler.schedule_calendar_replacement(meeting.id, "teams-event")

      start_running(meeting, "replace")

      assert {:ok, job} =
               CalendarEventScheduler.schedule_calendar_replacement(meeting.id, "teams-event")

      refute job.conflict?
    end

    test "collapses into a replacement of the same event that has not started yet" do
      meeting = insert(:meeting)

      assert {:ok, _job} =
               CalendarEventScheduler.schedule_calendar_replacement(meeting.id, "teams-event")

      assert {:ok, job} =
               CalendarEventScheduler.schedule_calendar_replacement(meeting.id, "teams-event")

      assert job.conflict?
    end
  end

  # Oban's uniqueness looks at the rows in the table, so moving the job to
  # `executing` is what the next insert actually meets.
  defp start_running(meeting, action) do
    {1, _rows} =
      Repo.update_all(
        from(j in Oban.Job,
          where: fragment("?->>'action' = ?", j.args, ^action),
          where: fragment("?->>'meeting_id' = ?", j.args, ^meeting.id),
          where: j.state == "available"
        ),
        set: [state: "executing"]
      )

    :ok
  end

  describe "priority_for_action/1" do
    test "maps known actions to documented priorities" do
      assert CalendarJobs.priority_for_action("create") == 0
      assert CalendarJobs.priority_for_action("update") == 2
    end

    test "falls back to mid priority for unknown actions" do
      assert CalendarJobs.priority_for_action("delete") == 1
      assert CalendarJobs.priority_for_action("other") == 1
    end
  end
end
