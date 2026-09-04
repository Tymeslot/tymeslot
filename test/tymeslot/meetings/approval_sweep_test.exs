defmodule Tymeslot.Meetings.ApprovalSweepTest do
  @moduledoc """
  What happens when a release itself blows up mid-expiry, rather than the
  ordinary "already answered" outcome both expiry paths otherwise handle.

  Neither `ApprovalExpiryWorker` nor `ApprovalSweepWorker` gets a second
  attempt at a meeting whose row has not moved: the per-meeting job runs
  once, and the sweep will not re-select a row it never changed the status
  of. So a crash here must be caught and made visible rather than left to
  either propagate uncaught or be folded into a routine, silent outcome.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker
  alias Tymeslot.Meetings.Workers.ApprovalSweepWorker
  alias Tymeslot.Repo

  defp overdue_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), -1, :hour)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp mock_expire_raise do
    :meck.new(Approval, [:passthrough])
    :meck.expect(Approval, :expire, fn _meeting -> raise "boom" end)

    on_exit(fn ->
      # Oban's own crash handling for the discarded job can run its course
      # after the assertion below already completed, so the mock may be
      # unloaded already by the time this fires.
      try do
        :meck.unload(Approval)
      rescue
        _error -> :ok
      end
    end)
  end

  describe "ApprovalExpiryWorker — a release that raises" do
    test "is caught and reported rather than crashing the job uncaught" do
      meeting = overdue_meeting()
      mock_expire_raise()

      assert {:error, %RuntimeError{}} =
               perform_job(ApprovalExpiryWorker, %{"meeting_id" => meeting.id})

      assert reload(meeting).status == "awaiting_approval"
    end
  end

  describe "ApprovalSweepWorker — a release that raises" do
    test "is tallied separately from the benign 'already answered' skip" do
      meeting = overdue_meeting()
      mock_expire_raise()

      assert {:ok, %{expired: 0, skipped: 0, failed: 1}} =
               perform_job(ApprovalSweepWorker, %{})

      assert reload(meeting).status == "awaiting_approval"
    end
  end
end
