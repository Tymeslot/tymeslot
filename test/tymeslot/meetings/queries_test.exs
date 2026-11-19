defmodule Tymeslot.Meetings.QueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Ecto.UUID
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries

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
      # attendee_email is never consulted: an attendee holding a Tymeslot
      # account under the booking email must not be treated as authorised to
      # act on their own request.
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
        status: :awaiting_approval
      )

      assert_raise Ecto.ConstraintError, fn ->
        insert(:meeting,
          organizer_user_id: organizer.id,
          start_time: start_time,
          status: :awaiting_approval
        )
      end
    end

    test "rejects a confirmed meeting colliding with an existing held request" do
      organizer = insert(:user)
      start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_user_id: organizer.id,
        start_time: start_time,
        status: :awaiting_approval
      )

      assert_raise Ecto.ConstraintError, fn ->
        insert(:meeting,
          organizer_user_id: organizer.id,
          start_time: start_time,
          status: :confirmed
        )
      end
    end
  end

  describe "list_expired_verifications/2" do
    test "returns only lapsed held bookings, oldest first" do
      now = DateTime.utc_now(:second)

      newer =
        insert(:meeting,
          status: :awaiting_verification,
          verification_deadline_at: DateTime.add(now, -60)
        )

      older =
        insert(:meeting,
          status: :awaiting_verification,
          verification_deadline_at: DateTime.add(now, -600)
        )

      _future =
        insert(:meeting,
          status: :awaiting_verification,
          verification_deadline_at: DateTime.add(now, 600)
        )

      _done =
        insert(:meeting, status: :expired, verification_deadline_at: DateTime.add(now, -900))

      assert [older.id, newer.id] ==
               now |> MeetingQueries.list_expired_verifications(10) |> Enum.map(& &1.id)

      assert [older.id] ==
               now |> MeetingQueries.list_expired_verifications(1) |> Enum.map(& &1.id)
    end
  end
end
