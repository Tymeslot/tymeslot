defmodule Tymeslot.Meetings.MeetingQueriesExpandedTest do
  @moduledoc """
  Expanded tests for MeetingQueries - covering CRUD and listing functions.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingQueries

  # Helper to build meeting times
  defp build_meeting_times(offset_days, duration_minutes) do
    start_time =
      DateTime.utc_now()
      |> DateTime.add(offset_days, :day)
      |> DateTime.truncate(:second)

    end_time = DateTime.add(start_time, duration_minutes, :minute)
    {start_time, end_time}
  end

  describe "create_meeting/1" do
    test "creates a meeting with valid attributes" do
      {start_time, end_time} = build_meeting_times(1, 60)

      attrs = %{
        uid: "test-uid-#{System.unique_integer([:positive])}",
        title: "Test Meeting",
        start_time: start_time,
        end_time: end_time,
        organizer_name: "Test Organizer",
        organizer_email: "organizer@example.com",
        attendee_name: "Test Attendee",
        attendee_email: "attendee@example.com"
      }

      assert {:ok, meeting} = MeetingQueries.create_meeting(attrs)
      assert meeting.title == "Test Meeting"
      assert meeting.organizer_email == "organizer@example.com"
    end

    test "returns error for invalid attributes" do
      # Missing required fields
      assert {:error, changeset} = MeetingQueries.create_meeting(%{})
      assert changeset.valid? == false
    end
  end

  describe "get_meeting/1" do
    test "returns meeting when it exists" do
      meeting = insert(:meeting)

      assert {:ok, found} = MeetingQueries.get_meeting(meeting.id)
      assert found.id == meeting.id
    end

    test "returns error when meeting does not exist" do
      assert {:error, :not_found} = MeetingQueries.get_meeting(UUID.generate())
    end
  end

  describe "get_meeting_by_uid/1" do
    test "returns meeting when UID exists" do
      meeting = insert(:meeting)

      assert {:ok, found} = MeetingQueries.get_meeting_by_uid(meeting.uid)
      assert found.id == meeting.id
      assert found.uid == meeting.uid
    end

    test "returns error when UID does not exist" do
      assert {:error, :not_found} = MeetingQueries.get_meeting_by_uid("non-existent-uid")
    end
  end

  describe "update_meeting/2" do
    test "updates meeting with valid attributes" do
      meeting = insert(:meeting)

      assert {:ok, updated} = MeetingQueries.update_meeting(meeting, %{title: "Updated Title"})
      assert updated.title == "Updated Title"
    end

    test "updates meeting status" do
      meeting = insert(:meeting, status: "confirmed")

      assert {:ok, updated} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})
      assert updated.status == "cancelled"
    end
  end

  describe "delete_meeting/1" do
    test "deletes an existing meeting" do
      meeting = insert(:meeting)

      assert {:ok, deleted} = MeetingQueries.delete_meeting(meeting)
      assert {:error, :not_found} = MeetingQueries.get_meeting(deleted.id)
    end
  end

  describe "list_meetings/0" do
    test "returns all meetings ordered by start time desc" do
      {start1, end1} = build_meeting_times(1, 60)
      {start2, end2} = build_meeting_times(2, 60)

      meeting1 = insert(:meeting, start_time: start1, end_time: end1)
      meeting2 = insert(:meeting, start_time: start2, end_time: end2)

      meetings = MeetingQueries.list_meetings()

      # Meeting2 has later start time so should be first (desc order)
      assert hd(meetings).id == meeting2.id
      assert List.last(meetings).id == meeting1.id
    end

    test "returns empty list when no meetings" do
      assert MeetingQueries.list_meetings() == []
    end
  end

  describe "list_meetings_by_status/1" do
    test "returns only meetings with specified status" do
      insert(:meeting, status: "confirmed")
      insert(:meeting, status: "confirmed")
      insert(:meeting, status: "cancelled")

      confirmed = MeetingQueries.list_meetings_by_status("confirmed")
      cancelled = MeetingQueries.list_meetings_by_status("cancelled")

      assert length(confirmed) == 2
      assert length(cancelled) == 1
    end

    test "returns empty list for status with no meetings" do
      insert(:meeting, status: "confirmed")

      assert MeetingQueries.list_meetings_by_status("cancelled") == []
    end
  end

  describe "list_upcoming_meetings/0" do
    test "returns only future meetings" do
      {future_start, future_end} = build_meeting_times(1, 60)

      past_start = DateTime.add(DateTime.utc_now(), -1, :day)
      past_end = DateTime.add(past_start, 60, :minute)

      future_meeting = insert(:meeting, start_time: future_start, end_time: future_end)
      _past_meeting = insert(:meeting, start_time: past_start, end_time: past_end)

      upcoming = MeetingQueries.list_upcoming_meetings()

      assert length(upcoming) == 1
      assert hd(upcoming).id == future_meeting.id
    end
  end

  describe "list_meetings_by_date_range/2" do
    test "returns meetings within the date range" do
      # Create meeting in the target range
      start_time = DateTime.new!(~D[2025-06-15], ~T[10:00:00], "Etc/UTC")
      end_time = DateTime.add(start_time, 60, :minute)
      meeting_in_range = insert(:meeting, start_time: start_time, end_time: end_time)

      # Create meeting outside the range
      outside_start = DateTime.new!(~D[2025-06-20], ~T[10:00:00], "Etc/UTC")
      outside_end = DateTime.add(outside_start, 60, :minute)
      _outside_meeting = insert(:meeting, start_time: outside_start, end_time: outside_end)

      range_start = DateTime.new!(~D[2025-06-14], ~T[00:00:00], "Etc/UTC")
      range_end = DateTime.new!(~D[2025-06-16], ~T[23:59:59], "Etc/UTC")

      meetings = MeetingQueries.list_meetings_by_date_range(range_start, range_end)

      assert length(meetings) == 1
      assert hd(meetings).id == meeting_in_range.id
    end

    test "returns empty list when no meetings in range" do
      start_time = DateTime.new!(~D[2025-06-15], ~T[10:00:00], "Etc/UTC")
      end_time = DateTime.add(start_time, 60, :minute)
      _meeting = insert(:meeting, start_time: start_time, end_time: end_time)

      # Range that doesn't include the meeting
      range_start = DateTime.new!(~D[2025-07-01], ~T[00:00:00], "Etc/UTC")
      range_end = DateTime.new!(~D[2025-07-31], ~T[23:59:59], "Etc/UTC")

      meetings = MeetingQueries.list_meetings_by_date_range(range_start, range_end)

      assert meetings == []
    end
  end

  describe "list_meetings_by_attendee_email/1" do
    test "returns meetings for specified attendee" do
      meeting1 = insert(:meeting, attendee_email: "john@example.com")
      _meeting2 = insert(:meeting, attendee_email: "jane@example.com")

      meetings = MeetingQueries.list_meetings_by_attendee_email("john@example.com")

      assert length(meetings) == 1
      assert hd(meetings).id == meeting1.id
    end
  end

  describe "list_meetings_by_organizer_email/1" do
    test "returns meetings for specified organizer" do
      meeting1 = insert(:meeting, organizer_email: "organizer1@example.com")
      _meeting2 = insert(:meeting, organizer_email: "organizer2@example.com")

      meetings = MeetingQueries.list_meetings_by_organizer_email("organizer1@example.com")

      assert length(meetings) == 1
      assert hd(meetings).id == meeting1.id
    end
  end

  describe "list_user_meetings_missing_video_rooms/3" do
    defp future_times(offset_days) do
      start_time =
        DateTime.utc_now()
        |> DateTime.add(offset_days, :day)
        |> DateTime.truncate(:second)

      {start_time, DateTime.add(start_time, 60, :minute)}
    end

    defp missing_video_room_meeting(user, video_integration, offset_days) do
      {start_time, end_time} = future_times(offset_days)

      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        status: "confirmed",
        video_integration_id: video_integration.id,
        video_room_id: nil,
        start_time: start_time,
        end_time: end_time
      )
    end

    test "returns confirmed upcoming meetings missing a video room for the user" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user)
      meeting = missing_video_room_meeting(user, video_integration, 2)

      results = MeetingQueries.list_user_meetings_missing_video_rooms(user.id, DateTime.utc_now())

      assert length(results) == 1
      assert hd(results).id == meeting.id
    end

    test "excludes meetings that already have a video_room_id" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user)
      {start_time, end_time} = future_times(2)

      _has_room =
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          status: "confirmed",
          video_integration_id: video_integration.id,
          video_room_id: "room-already-created",
          start_time: start_time,
          end_time: end_time
        )

      assert [] =
               MeetingQueries.list_user_meetings_missing_video_rooms(user.id, DateTime.utc_now())
    end

    test "excludes non-confirmed meetings" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user)
      {start_time, end_time} = future_times(2)

      _cancelled =
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          status: "cancelled",
          video_integration_id: video_integration.id,
          video_room_id: nil,
          start_time: start_time,
          end_time: end_time
        )

      assert [] =
               MeetingQueries.list_user_meetings_missing_video_rooms(user.id, DateTime.utc_now())
    end

    test "excludes past meetings" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user)

      past_start =
        DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      past_end = DateTime.add(past_start, 60, :minute)

      _past =
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          status: "confirmed",
          video_integration_id: video_integration.id,
          video_room_id: nil,
          start_time: past_start,
          end_time: past_end
        )

      assert [] =
               MeetingQueries.list_user_meetings_missing_video_rooms(user.id, DateTime.utc_now())
    end

    test "excludes meetings with a null video_integration_id" do
      user = insert(:user)
      {start_time, end_time} = future_times(2)

      _no_integration =
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          status: "confirmed",
          video_integration_id: nil,
          video_room_id: nil,
          start_time: start_time,
          end_time: end_time
        )

      assert [] =
               MeetingQueries.list_user_meetings_missing_video_rooms(user.id, DateTime.utc_now())
    end

    test "excludes meetings belonging to a different user" do
      user = insert(:user)
      other_user = insert(:user)
      video_integration = insert(:video_integration, user: other_user)

      _other_meeting = missing_video_room_meeting(other_user, video_integration, 2)

      assert [] =
               MeetingQueries.list_user_meetings_missing_video_rooms(user.id, DateTime.utc_now())
    end

    test "honours the limit parameter" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user)

      for offset <- [2, 3, 4] do
        missing_video_room_meeting(user, video_integration, offset)
      end

      results =
        MeetingQueries.list_user_meetings_missing_video_rooms(user.id, DateTime.utc_now(), 2)

      assert length(results) == 2
    end

    test "returns results ordered by start_time ascending" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user)

      later = missing_video_room_meeting(user, video_integration, 5)
      sooner = missing_video_room_meeting(user, video_integration, 2)

      results = MeetingQueries.list_user_meetings_missing_video_rooms(user.id, DateTime.utc_now())

      assert Enum.map(results, & &1.id) == [sooner.id, later.id]
    end
  end
end
