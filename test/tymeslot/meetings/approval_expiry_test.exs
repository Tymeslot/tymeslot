defmodule Tymeslot.Meetings.ApprovalExpiryTest do
  @moduledoc """
  The clock behind the approval gate: the scheduled expiry, the cron sweep,
  and the job cancellation that stops both once a host has answered.

  The user-visible failure these guard against is a request that resolves to
  nothing. An invitee told their time is held until Thursday and then never
  told anything again is worse than a decline, and it is exactly what a lost
  expiry job produces. Hence two independent paths to the same release, and
  tests that each one works when the other does not.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings

  alias Ecto.UUID
  alias Oban.Job
  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.ApprovalJobs
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker
  alias Tymeslot.Meetings.Workers.ApprovalSweepWorker
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  defp held_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  defp overdue_meeting(attrs \\ %{}) do
    held_meeting(
      Map.merge(
        %{approval_deadline_at: DateTime.add(DateTime.utc_now(:second), -1, :hour)},
        attrs
      )
    )
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  describe "ApprovalJobs.schedule_expiry/1" do
    test "schedules the release for the deadline, not for now" do
      meeting = held_meeting()

      assert :ok = ApprovalJobs.schedule_expiry(meeting)

      assert_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => meeting.id})

      job = Repo.get_by!(Job, worker: "Tymeslot.Meetings.Workers.ApprovalExpiryWorker")
      assert DateTime.compare(job.scheduled_at, meeting.approval_deadline_at) == :eq
    end

    test "a request with no deadline is held until somebody answers" do
      meeting = held_meeting(%{approval_deadline_at: nil})

      assert :ok = ApprovalJobs.schedule_expiry(meeting)

      refute_enqueued(worker: ApprovalExpiryWorker)
    end

    test "re-scheduling replaces the old job rather than losing to its uniqueness" do
      meeting = held_meeting()
      :ok = ApprovalJobs.schedule_expiry(meeting)

      new_deadline = DateTime.add(meeting.approval_deadline_at, 11, :hour)
      rearmed = %{meeting | approval_deadline_at: new_deadline}
      assert :ok = ApprovalJobs.schedule_expiry(rearmed)

      jobs =
        Enum.filter(
          Repo.all(Job),
          &(&1.worker == "Tymeslot.Meetings.Workers.ApprovalExpiryWorker")
        )

      assert [only_job] = jobs
      assert DateTime.compare(only_job.scheduled_at, new_deadline) == :eq
    end
  end

  describe "ApprovalJobs.cancel/1" do
    test "removes a pending expiry" do
      meeting = held_meeting()
      :ok = ApprovalJobs.schedule_expiry(meeting)

      assert :ok = ApprovalJobs.cancel(meeting)

      refute_enqueued(worker: ApprovalExpiryWorker)
    end

    test "leaves another meeting's expiry alone" do
      mine = held_meeting()
      theirs = held_meeting()
      :ok = ApprovalJobs.schedule_expiry(mine)
      :ok = ApprovalJobs.schedule_expiry(theirs)

      :ok = ApprovalJobs.cancel(mine)

      refute_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => mine.id})
      assert_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => theirs.id})
    end
  end

  describe "answering the request clears its clock" do
    test "approving cancels the expiry that would have released the slot" do
      meeting = held_meeting()
      :ok = ApprovalJobs.schedule_expiry(meeting)

      {:ok, _confirmed} = Approval.approve(meeting)

      refute_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => meeting.id})
    end

    test "declining cancels it too" do
      meeting = held_meeting()
      :ok = ApprovalJobs.schedule_expiry(meeting)

      {:ok, _declined} = Approval.decline(meeting, "Away that week")

      refute_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => meeting.id})
    end

    test "declining also cancels the nudge, so nobody is asked to re-decide" do
      meeting = held_meeting()

      :ok =
        MeetingScheduler.schedule_approval_nudge(
          meeting.id,
          DateTime.add(DateTime.utc_now(:second), 12, :hour)
        )

      {:ok, _declined} = Approval.decline(meeting, nil)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_approval_nudge", "meeting_id" => meeting.id}
      )
    end
  end

  describe "releasing a request tells the invitee" do
    test "a decline schedules the declined email" do
      meeting = held_meeting()

      {:ok, _declined} = Approval.decline(meeting, "Not this month")

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_booking_request_outcome",
          "meeting_id" => meeting.id,
          "variant" => "declined"
        }
      )
    end

    test "an expiry schedules the expired email, which says something different" do
      meeting = overdue_meeting()

      {:ok, _expired} = Approval.expire(meeting)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_booking_request_outcome",
          "meeting_id" => meeting.id,
          "variant" => "expired"
        }
      )
    end

    test "a decline takes the tentative hold off the host's calendar" do
      # The hold is the whole reason the slot was unbookable. Leaving it behind
      # would keep the time blocked for a booking that is not happening.
      meeting = held_meeting()

      {:ok, _declined} = Approval.decline(meeting, nil)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => meeting.id}
      )
    end

    test "an expiry takes the hold off too" do
      meeting = overdue_meeting()

      {:ok, _expired} = Approval.expire(meeting)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => meeting.id}
      )
    end

    test "an approval leaves the calendar event in place to be confirmed" do
      meeting = held_meeting()

      {:ok, _confirmed} = Approval.approve(meeting)

      refute_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => meeting.id}
      )
    end

    test "an approval sends no outcome email — the confirmation is the news" do
      meeting = held_meeting()

      {:ok, _confirmed} = Approval.approve(meeting)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_outcome", "meeting_id" => meeting.id}
      )
    end
  end

  describe "ApprovalExpiryWorker" do
    test "releases a request still held at its deadline" do
      meeting = overdue_meeting()

      assert :ok = perform_job(ApprovalExpiryWorker, %{"meeting_id" => meeting.id})

      assert reload(meeting).status == "expired"
    end

    test "leaves a request the host already approved alone" do
      meeting = held_meeting()
      {:ok, _confirmed} = Approval.approve(meeting)

      assert {:discard, _reason} =
               perform_job(ApprovalExpiryWorker, %{"meeting_id" => meeting.id})

      assert reload(meeting).status == "confirmed"
    end

    test "discards rather than retries when the meeting is gone" do
      assert {:discard, _reason} =
               perform_job(ApprovalExpiryWorker, %{"meeting_id" => UUID.generate()})
    end

    test "discards a stale job whose meeting was re-armed with a later deadline" do
      # Still held, but the deadline this job carries is not the one on the
      # meeting any more — the request was re-scheduled after this job was
      # enqueued and its own replacement was lost.
      meeting =
        held_meeting(%{approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 6, :hour)})

      assert {:discard, _reason} =
               perform_job(ApprovalExpiryWorker, %{"meeting_id" => meeting.id})

      assert reload(meeting).status == "awaiting_approval"
    end
  end

  describe "ApprovalSweepWorker" do
    test "releases requests whose scheduled expiry never fired" do
      overdue = overdue_meeting()

      # The per-meeting job is deliberately absent: this is the case the sweep
      # exists for.
      refute_enqueued(worker: ApprovalExpiryWorker)

      assert {:ok, %{expired: 1}} = perform_job(ApprovalSweepWorker, %{})

      assert reload(overdue).status == "expired"
    end

    test "does not touch a request still inside its window" do
      inside = held_meeting()

      assert {:ok, %{expired: 0, skipped: 0}} = perform_job(ApprovalSweepWorker, %{})

      assert reload(inside).status == "awaiting_approval"
    end

    test "works through a backlog rather than stopping at the first" do
      overdue = Enum.map(1..3, fn _each -> overdue_meeting() end)

      assert {:ok, %{expired: 3}} = perform_job(ApprovalSweepWorker, %{})

      assert Enum.map(overdue, &reload(&1).status) == ["expired", "expired", "expired"]
    end

    test "an answered request is out of the sweep's reach entirely" do
      answered = overdue_meeting()
      {:ok, _confirmed} = Approval.approve(answered)

      assert {:ok, %{expired: 0, skipped: 0}} = perform_job(ApprovalSweepWorker, %{})

      assert reload(answered).status == "confirmed"
    end
  end
end
