defmodule Tymeslot.Meetings.ApprovalTest do
  @moduledoc """
  The manual-approval gate's transitions.

  The tests that matter most here are the concurrency ones: every exit from
  the gate races every other, and the guard that resolves them lives in a
  `WHERE` clause rather than in Elixir, so it has to be exercised against a
  real database rather than reasoned about.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Validation.Constraints

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

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  describe "required?/1" do
    test "follows the meeting type's flag" do
      assert Approval.required?(build(:meeting_type, requires_approval: true))
      refute Approval.required?(build(:meeting_type, requires_approval: false))
    end

    test "no meeting type means no gate" do
      refute Approval.required?(nil)
    end
  end

  describe "window_hours/1" do
    test "uses the meeting type's window when it stores one" do
      assert Approval.window_hours(build(:meeting_type, approval_window_hours: 6)) == 6
    end

    test "falls back to the application default when the meeting type stores none" do
      assert Approval.window_hours(build(:meeting_type, approval_window_hours: nil)) ==
               Constraints.default_approval_window_hours()
    end
  end

  describe "deadline_for/3" do
    test "is the request time plus the window" do
      requested_at = ~U[2026-03-01 09:00:00Z]
      start_time = ~U[2026-03-30 09:00:00Z]

      assert Approval.deadline_for(
               build(:meeting_type, approval_window_hours: 6),
               requested_at,
               start_time
             ) == ~U[2026-03-01 15:00:00Z]
    end

    test "never runs past the meeting's own start time" do
      requested_at = ~U[2026-03-01 09:00:00Z]
      start_time = ~U[2026-03-01 13:00:00Z]

      # A 24-hour window against a meeting four hours away would otherwise
      # promise the host a deadline long after the slot had come and gone.
      assert Approval.deadline_for(
               build(:meeting_type, approval_window_hours: 24),
               requested_at,
               start_time
             ) == start_time
    end
  end

  describe "approve/1" do
    test "confirms the booking and records when it was answered" do
      meeting = held_meeting()

      assert {:ok, confirmed} = Approval.approve(meeting)
      assert confirmed.status == "confirmed"

      stored = reload(meeting)
      assert stored.status == "confirmed"
      assert %DateTime{} = stored.approval_resolved_at
    end

    test "hands the confirmed booking to the ordinary notification pipeline" do
      meeting = held_meeting()

      assert {:ok, confirmed} = Approval.approve(meeting)

      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => confirmed.id}
      )
    end

    test "a second approval loses to the first rather than re-confirming" do
      meeting = held_meeting()

      assert {:ok, _confirmed} = Approval.approve(meeting)
      # The caller still holds the stale struct, exactly as a double-clicked
      # button or a second browser tab would.
      assert {:error, :not_awaiting_approval} = Approval.approve(meeting)
    end

    test "loses to an expiry that already released the slot" do
      meeting = held_meeting()

      assert {:ok, _expired} = Approval.expire(meeting)
      assert {:error, :not_awaiting_approval} = Approval.approve(meeting)

      assert reload(meeting).status == "expired"
    end

    test "refuses a request whose meeting has already started" do
      meeting =
        held_meeting(%{
          start_time: DateTime.add(DateTime.utc_now(:second), -1, :hour),
          end_time: DateTime.utc_now(:second)
        })

      assert {:error, :meeting_started} = Approval.approve(meeting)
      assert reload(meeting).status == "awaiting_approval"
    end
  end

  describe "decline/2" do
    test "releases the slot and keeps the host's reason" do
      meeting = held_meeting()

      assert {:ok, declined} = Approval.decline(meeting, "  Double-booked that morning  ")
      assert declined.status == "cancelled"

      stored = reload(meeting)
      assert stored.decline_reason == "Double-booked that morning"
      assert %DateTime{} = stored.cancelled_at
      assert %DateTime{} = stored.approval_resolved_at
    end

    test "a blank reason is stored as no reason at all" do
      meeting = held_meeting()

      assert {:ok, _declined} = Approval.decline(meeting, "   ")
      assert reload(meeting).decline_reason == nil
    end

    test "cannot decline a booking that was already approved" do
      meeting = held_meeting()

      assert {:ok, _confirmed} = Approval.approve(meeting)
      assert {:error, :not_awaiting_approval} = Approval.decline(meeting, "changed my mind")

      assert reload(meeting).status == "confirmed"
    end
  end

  describe "expire/1" do
    test "releases the slot without recording a decline reason" do
      meeting = held_meeting()

      assert {:ok, expired} = Approval.expire(meeting)
      assert expired.status == "expired"

      stored = reload(meeting)
      assert stored.decline_reason == nil
      assert %DateTime{} = stored.approval_resolved_at
    end
  end

  describe "MeetingQueries.list_expired_approval_requests/2" do
    test "selects held requests past their deadline, oldest first" do
      now = DateTime.utc_now(:second)

      long_overdue = held_meeting(%{approval_deadline_at: DateTime.add(now, -3, :hour)})
      just_overdue = held_meeting(%{approval_deadline_at: DateTime.add(now, -1, :hour)})
      still_running = held_meeting(%{approval_deadline_at: DateTime.add(now, 1, :hour)})
      already_answered = held_meeting(%{approval_deadline_at: DateTime.add(now, -5, :hour)})
      {:ok, _approved} = Approval.approve(already_answered)

      ids = now |> MeetingQueries.list_expired_approval_requests(10) |> Enum.map(& &1.id)

      assert ids == [long_overdue.id, just_overdue.id]
      refute still_running.id in ids
      refute already_answered.id in ids
    end
  end
end
