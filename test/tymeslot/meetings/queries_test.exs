defmodule Tymeslot.Meetings.QueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Ecto.UUID
  alias Tymeslot.Meetings

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

  describe "get_meeting_by_uid_for_user/2" do
    test "returns meeting when user is organizer" do
      meeting = insert(:meeting, organizer_email: "organizer@example.com")

      assert {:ok, found} =
               Meetings.get_meeting_by_uid_for_user(meeting.uid, "organizer@example.com")

      assert found.uid == meeting.uid
    end

    test "returns meeting when user is attendee" do
      meeting = insert(:meeting, attendee_email: "attendee@example.com")

      assert {:ok, found} =
               Meetings.get_meeting_by_uid_for_user(meeting.uid, "attendee@example.com")

      assert found.uid == meeting.uid
    end

    test "returns error when user is unauthorized" do
      meeting = insert(:meeting)

      assert {:error, :not_found} =
               Meetings.get_meeting_by_uid_for_user(meeting.uid, "unauthorized@example.com")
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

  describe "meetings_needing_reminders/0" do
    test "filters meetings based on reminder rules" do
      now = DateTime.utc_now()
      soon = DateTime.add(now, 30, :minute)

      meeting_needing_reminder =
        insert(:meeting,
          start_time: soon,
          status: "confirmed",
          reminder_email_sent: false,
          reminders: nil
        )

      _meeting_already_reminded =
        insert(:meeting,
          start_time: soon,
          status: "confirmed",
          reminder_email_sent: true,
          reminders: nil
        )

      _meeting_with_empty_reminders =
        insert(:meeting,
          start_time: soon,
          status: "confirmed",
          reminders: []
        )

      _meeting_fully_reminded =
        insert(:meeting,
          start_time: soon,
          status: "confirmed",
          reminders: [%{"value" => 30, "unit" => "minutes"}],
          reminders_sent: [%{"value" => 30, "unit" => "minutes"}]
        )

      meeting_with_pending_reminder =
        insert(:meeting,
          start_time: soon,
          status: "confirmed",
          reminders: [%{"value" => 1, "unit" => "hours"}],
          reminders_sent: []
        )

      _meeting_not_confirmed =
        insert(:meeting,
          start_time: soon,
          status: "pending",
          reminder_email_sent: false
        )

      _meeting_later =
        insert(:meeting,
          start_time: DateTime.add(now, 2, :hour),
          status: "confirmed",
          reminder_email_sent: false
        )

      meetings = Meetings.meetings_needing_reminders()
      meeting_ids = Enum.map(meetings, & &1.id)

      assert meeting_needing_reminder.id in meeting_ids
      assert meeting_with_pending_reminder.id in meeting_ids
      assert length(meeting_ids) == 2
    end
  end
end
