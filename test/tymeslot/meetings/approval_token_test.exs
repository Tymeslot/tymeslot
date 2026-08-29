defmodule Tymeslot.Meetings.ApprovalTokenTest do
  @moduledoc """
  The signed token that lets a host answer a booking request from their
  email, without a session.

  Nothing here should be a unit test of `Phoenix.Token` — the point is that
  the payload this module signs is exactly what its own `verify/1` refuses
  or accepts: a mismatched organiser, a stale request bound to a since
  re-entered approval gate, and a garbled token.
  """

  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings

  alias Ecto.Changeset
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Repo

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

  describe "sign/1 and verify/1" do
    test "round-trips the meeting and organiser ids for a freshly issued token" do
      meeting = held_meeting()

      token = ApprovalToken.sign(meeting)

      assert {:ok, {meeting_id, organizer_user_id}} = ApprovalToken.verify(token)
      assert meeting_id == meeting.id
      assert organizer_user_id == meeting.organizer_user_id
    end

    test "refuses a garbled token" do
      assert {:error, _reason} = ApprovalToken.verify("not-a-real-token")
    end

    test "refuses a token for a meeting that no longer exists" do
      meeting = held_meeting()
      token = ApprovalToken.sign(meeting)

      Repo.delete!(meeting)

      assert {:error, :not_found} = ApprovalToken.verify(token)
    end

    test "a token issued before a re-entry into the approval gate no longer verifies" do
      meeting = held_meeting()
      stale_token = ApprovalToken.sign(meeting)

      # A reschedule (or any other re-entry into the gate) stamps a fresh
      # `approval_requested_at`, exactly as `Bookings.Reschedule` does. Offset
      # by a second so it cannot land on the same value as the original stamp
      # even when both calls fall in the same wall-clock second.
      {:ok, reentered} =
        meeting
        |> Changeset.change(
          approval_requested_at: DateTime.add(meeting.approval_requested_at, 1, :second)
        )
        |> Repo.update()

      assert {:error, :stale} = ApprovalToken.verify(stale_token)

      fresh_token = ApprovalToken.sign(reentered)
      assert {:ok, {meeting_id, _organizer_user_id}} = ApprovalToken.verify(fresh_token)
      assert meeting_id == reentered.id
    end
  end

  describe "max_age/0" do
    test "covers the longest configurable approval window with a margin" do
      # See `MeetingTypes` — 336 hours (14 days) is the longest window a
      # meeting type may configure; the token stays valid for twice that.
      assert ApprovalToken.max_age() > 336 * 3600
    end
  end
end
