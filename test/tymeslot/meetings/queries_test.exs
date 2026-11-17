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

  describe "transition_from_awaiting_approval/2 unique-violation handling" do
    test "returns {:error, :slot_taken} instead of raising when the target slot is already occupied" do
      organizer = insert(:user)
      taken_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_user_id: organizer.id,
        start_time: taken_time,
        end_time: DateTime.add(taken_time, 3600, :second),
        status: :confirmed
      )

      held_start = DateTime.add(taken_time, 7200, :second)

      held =
        insert(:meeting,
          organizer_user_id: organizer.id,
          start_time: held_start,
          end_time: DateTime.add(held_start, 3600, :second),
          status: :awaiting_approval
        )

      # `changes` is a plain keyword list — the function's contract allows any
      # column, not only `status`. Moving this held row's own start_time onto
      # the already-occupied slot is the most direct way to trigger the same
      # unique-index collision the raw `Repo.update_all` has no changeset to
      # translate.
      assert {:error, :slot_taken} =
               MeetingQueries.transition_from_awaiting_approval(
                 held.id,
                 status: :confirmed,
                 start_time: taken_time
               )

      reloaded = Repo.get!(MeetingSchema, held.id)
      assert reloaded.status == :awaiting_approval
      assert reloaded.start_time == held.start_time
    end
  end

  describe "transition_from_awaiting_verification/3" do
    test "the verification transition moves only a held booking" do
      held = insert(:meeting, status: :awaiting_verification)
      confirmed = insert(:meeting, status: :confirmed)

      assert {:ok, %{status: :confirmed}} =
               MeetingQueries.transition_from_awaiting_verification(held.id, status: :confirmed)

      assert {:error, :not_awaiting_verification} =
               MeetingQueries.transition_from_awaiting_verification(confirmed.id,
                 status: :cancelled
               )

      assert Repo.reload!(confirmed).status == :confirmed
    end

    test "two transitions race and one wins" do
      held = insert(:meeting, status: :awaiting_verification)

      results =
        for _attempt <- 1..2 do
          MeetingQueries.transition_from_awaiting_verification(held.id, status: :confirmed)
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :not_awaiting_verification} in results
    end

    test "with a deadline guard, refuses a booking whose deadline has passed" do
      now = DateTime.utc_now(:second)
      lapsed = insert(:meeting, status: :awaiting_verification, verification_deadline_at: now)

      open =
        insert(:meeting,
          status: :awaiting_verification,
          verification_deadline_at: DateTime.add(now, 60)
        )

      assert {:error, :not_awaiting_verification} =
               MeetingQueries.transition_from_awaiting_verification(
                 lapsed.id,
                 [status: :confirmed],
                 deadline_after: now
               )

      assert Repo.reload!(lapsed).status == :awaiting_verification

      assert {:ok, %{status: :confirmed}} =
               MeetingQueries.transition_from_awaiting_verification(
                 open.id,
                 [status: :confirmed],
                 deadline_after: now
               )

      # Releases carry no deadline guard.
      assert {:ok, %{status: :expired}} =
               MeetingQueries.transition_from_awaiting_verification(lapsed.id, status: :expired)
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
