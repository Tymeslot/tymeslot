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

  import Tymeslot.Factory

  alias Tymeslot.Bookings.CalendarJobs
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
