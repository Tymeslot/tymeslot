defmodule Tymeslot.Meetings.QueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Ecto.UUID
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  describe "get_meeting_for_user/2" do
    test "returns meeting when user is organizer" do
      meeting = insert(:meeting, organizer_email: "organizer@example.com")

      assert {:ok, found} = Meetings.get_meeting_for_user(meeting.id, "organizer@example.com")
      assert found.id == meeting.id
    end

    test "returns meeting when user is attendee" do
      meeting = insert(:meeting, attendee_email: "attendee@example.com")

      assert {:ok, found} = Meetings.get_meeting_for_user(meeting.id, "attendee@example.com")
      assert found.id == meeting.id
    end

    test "returns error when user is neither organizer nor attendee" do
      meeting = insert(:meeting)

      assert {:error, :not_found} = Meetings.get_meeting_for_user(meeting.id, "other@example.com")
    end
  end

  describe "get_meeting_for_organizer/2" do
    test "returns meeting when organizer_user_id matches" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert {:ok, found} = Meetings.get_meeting_for_organizer(meeting.id, user.id)
      assert found.id == meeting.id
    end

    test "returns error when organizer_user_id does not match" do
      user = insert(:user)
      other_user = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert {:error, :not_found} =
               Meetings.get_meeting_for_organizer(meeting.id, other_user.id)
    end

    test "returns error when the requester is only the attendee, not the organizer" do
      # Unlike get_meeting_for_user/2, attendee_email is never consulted here:
      # an attendee holding a Tymeslot account under the booking email must
      # not be treated as authorised to act on their own request.
      user = insert(:user)
      attendee = insert(:user)

      meeting =
        insert(:meeting, organizer_user_id: user.id, attendee_email: attendee.email)

      assert {:error, :not_found} = Meetings.get_meeting_for_organizer(meeting.id, attendee.id)
    end

    test "returns error for non-existent id" do
      user = insert(:user)

      assert {:error, :not_found} =
               Meetings.get_meeting_for_organizer(UUID.generate(), user.id)
    end
  end

  describe "get_meeting_by_uid_for_organizer/2" do
    test "returns meeting when organizer_user_id matches" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert {:ok, found} = Meetings.get_meeting_by_uid_for_organizer(meeting.uid, user.id)
      assert found.uid == meeting.uid
    end

    test "returns error when organizer_user_id does not match" do
      user = insert(:user)
      other_user = insert(:user)
      meeting = insert(:meeting, organizer_user_id: user.id)

      assert {:error, :not_found} =
               Meetings.get_meeting_by_uid_for_organizer(meeting.uid, other_user.id)
    end

    test "returns error for non-existent UID" do
      user = insert(:user)

      assert {:error, :not_found} =
               Meetings.get_meeting_by_uid_for_organizer("nonexistent-uid", user.id)
    end
  end

  describe "unique_confirmed_meeting_per_organizer_at_time index" do
    test "rejects a second awaiting_approval meeting for the same organizer and start time" do
      organizer = insert(:user)
      start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_user_id: organizer.id,
        start_time: start_time,
        status: "awaiting_approval"
      )

      assert_raise Ecto.ConstraintError, fn ->
        insert(:meeting,
          organizer_user_id: organizer.id,
          start_time: start_time,
          status: "awaiting_approval"
        )
      end
    end

    test "rejects a confirmed meeting colliding with an existing held request" do
      organizer = insert(:user)
      start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_user_id: organizer.id,
        start_time: start_time,
        status: "awaiting_approval"
      )

      assert_raise Ecto.ConstraintError, fn ->
        insert(:meeting,
          organizer_user_id: organizer.id,
          start_time: start_time,
          status: "confirmed"
        )
      end
    end
  end

  describe "transition_from_awaiting_approval/2 unique-violation handling" do
    test "returns {:error, :slot_taken} instead of raising when the target slot is already occupied" do
      organizer = insert(:user)
      taken_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_user_id: organizer.id,
        start_time: taken_time,
        end_time: DateTime.add(taken_time, 3600, :second),
        status: "confirmed"
      )

      held_start = DateTime.add(taken_time, 7200, :second)

      held =
        insert(:meeting,
          organizer_user_id: organizer.id,
          start_time: held_start,
          end_time: DateTime.add(held_start, 3600, :second),
          status: "awaiting_approval"
        )

      # `changes` is a plain keyword list — the function's contract allows any
      # column, not only `status`. Moving this held row's own start_time onto
      # the already-occupied slot is the most direct way to trigger the same
      # unique-index collision the raw `Repo.update_all` has no changeset to
      # translate.
      assert {:error, :slot_taken} =
               MeetingQueries.transition_from_awaiting_approval(
                 held.id,
                 status: "confirmed",
                 start_time: taken_time
               )

      reloaded = Repo.get!(MeetingSchema, held.id)
      assert reloaded.status == "awaiting_approval"
      assert reloaded.start_time == held.start_time
    end
  end
end
