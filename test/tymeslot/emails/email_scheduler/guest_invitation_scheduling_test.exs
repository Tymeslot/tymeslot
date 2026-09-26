defmodule Tymeslot.Emails.EmailScheduler.GuestInvitationSchedulingTest do
  @moduledoc """
  A guest added while the invitation job is running still gets invited.

  The mirror of the calendar scheduler's rule: a job that has already read what
  it works from cannot carry a change made afterwards, so a second one must be
  allowed alongside it.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Ecto.Query

  alias Ecto.UUID
  alias Oban.Job
  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler

  describe "schedule_guest_invitations/1" do
    test "collapses into a job that has not started yet" do
      meeting_id = UUID.generate()

      assert :ok = MeetingScheduler.schedule_guest_invitations(meeting_id)
      assert :ok = MeetingScheduler.schedule_guest_invitations(meeting_id)

      assert jobs_for(meeting_id) == 1
    end

    test "still enqueues while another invitation job for the same meeting is executing" do
      meeting_id = UUID.generate()
      assert :ok = MeetingScheduler.schedule_guest_invitations(meeting_id)
      start_running(meeting_id)

      assert :ok = MeetingScheduler.schedule_guest_invitations(meeting_id)

      assert jobs_for(meeting_id) == 2
    end

    test "keeps meetings apart" do
      one = UUID.generate()
      two = UUID.generate()

      assert :ok = MeetingScheduler.schedule_guest_invitations(one)
      assert :ok = MeetingScheduler.schedule_guest_invitations(two)

      assert jobs_for(one) == 1
      assert jobs_for(two) == 1
    end
  end

  defp jobs_for(meeting_id) do
    Repo.aggregate(
      from(j in Job,
        where: fragment("?->>'action' = ?", j.args, "send_guest_invitations"),
        where: fragment("?->>'meeting_id' = ?", j.args, ^meeting_id)
      ),
      :count
    )
  end

  defp start_running(meeting_id) do
    {1, _rows} =
      Repo.update_all(
        from(j in Job,
          where: fragment("?->>'action' = ?", j.args, "send_guest_invitations"),
          where: fragment("?->>'meeting_id' = ?", j.args, ^meeting_id),
          where: j.state == "available"
        ),
        set: [state: "executing"]
      )

    :ok
  end
end
