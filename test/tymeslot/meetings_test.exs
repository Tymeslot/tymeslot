defmodule Tymeslot.MeetingsTest do
  @moduledoc """
  Tests for the Meetings context module.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  import Mox

  alias Ecto.UUID
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  import Tymeslot.MeetingTestHelpers
  import Tymeslot.CursorPaginationTestCases

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  describe "create_datetime_safe/3" do
    test "creates datetime with valid timezone" do
      date = ~D[2025-06-15]
      time = ~T[14:30:00]
      timezone = "America/New_York"

      result = Meetings.create_datetime_safe(date, time, timezone)

      assert %DateTime{} = result
      assert result.year == 2025
      assert result.month == 6
      assert result.day == 15
      assert result.hour == 14
      assert result.minute == 30
      assert result.time_zone == "America/New_York"
    end

    test "falls back to UTC for invalid timezone" do
      date = ~D[2025-06-15]
      time = ~T[14:30:00]
      invalid_timezone = "Invalid/Timezone"

      result = Meetings.create_datetime_safe(date, time, invalid_timezone)

      assert %DateTime{} = result
      assert result.time_zone == "Etc/UTC"
    end

    test "handles UTC timezone" do
      date = ~D[2025-06-15]
      time = ~T[14:30:00]

      result = Meetings.create_datetime_safe(date, time, "Etc/UTC")

      assert %DateTime{} = result
      assert result.time_zone == "Etc/UTC"
    end
  end

  describe "list_upcoming_meetings_for_user/1" do
    test "returns upcoming meetings for user" do
      %{user: user} = create_user_with_profile()

      upcoming_meeting = insert_meeting_for_user(user)

      _past_meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      result = Meetings.list_upcoming_meetings_for_user(user.email)

      assert length(result) == 1
      assert hd(result).id == upcoming_meeting.id
    end

    test "returns empty list for user with no meetings" do
      %{user: user} = create_user_with_profile()

      result = Meetings.list_upcoming_meetings_for_user(user.email)

      assert result == []
    end
  end

  describe "list_past_meetings_for_user/1" do
    test "returns past meetings for user" do
      %{user: user} = create_user_with_profile()

      # Create a past meeting
      past_meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      # Create an upcoming meeting (should not be returned)
      _upcoming_meeting = insert_meeting_for_user(user)

      result = Meetings.list_past_meetings_for_user(user.email)

      assert length(result) == 1
      assert hd(result).id == past_meeting.id
    end

    test "returns empty list for user with no past meetings" do
      %{user: user} = create_user_with_profile()

      result = Meetings.list_past_meetings_for_user(user.email)

      assert result == []
    end
  end

  describe "list_cancelled_meetings_for_user/1" do
    test "returns cancelled meetings for user" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      # Create a cancelled meeting
      cancelled_meeting =
        insert(:meeting,
          organizer_email: user.email,
          organizer_user_id: user.id,
          status: "cancelled",
          start_time: DateTime.add(DateTime.utc_now(), 86_400, :second),
          end_time: DateTime.add(DateTime.utc_now(), 90_000, :second)
        )

      # Create a confirmed meeting (should not be returned)
      _confirmed_meeting =
        insert(:meeting,
          organizer_email: user.email,
          organizer_user_id: user.id,
          status: "confirmed",
          start_time: DateTime.add(DateTime.utc_now(), 86_400, :second),
          end_time: DateTime.add(DateTime.utc_now(), 90_000, :second)
        )

      result = Meetings.list_cancelled_meetings_for_user(user.email)

      assert length(result) == 1
      assert hd(result).id == cancelled_meeting.id
    end
  end

  describe "get_meeting!/1" do
    test "returns meeting when it exists" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          status: "confirmed"
        )

      result = Meetings.get_meeting!(meeting.id)

      assert result.id == meeting.id
      assert result.uid == meeting.uid
    end

    test "raises when meeting does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Meetings.get_meeting!(UUID.generate())
      end
    end
  end

  describe "add_video_room_to_meeting/1" do
    test "successfully adds video room and logs activity" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      # Mock video integration
      video_integration =
        insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: video_integration.id
        )

      # Use setup_all_mocks to configure Mox correctly
      TestMocks.setup_all_mocks()

      # Stub HTTP client to return Req.Response struct
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             "{\"room_id\": \"test-room\", \"meeting_url\": \"https://test.mirotalk.com/join/test-room\", \"join\": \"https://test.mirotalk.com/join/test-room\"}"
         }}
      end)

      assert {:ok, %MeetingSchema{} = updated_meeting} =
               Meetings.add_video_room_to_meeting(meeting.id)

      assert updated_meeting.video_room_id != nil
      assert updated_meeting.video_room_enabled == true
      assert updated_meeting.id == meeting.id
    end

    test "returns :meeting_not_found for non-existent meeting" do
      assert {:error, :meeting_not_found} = Meetings.add_video_room_to_meeting(UUID.generate())
    end

    test "successfully adds custom video room" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      video_integration =
        insert(:video_integration,
          user: user,
          provider: "custom",
          is_active: true,
          custom_meeting_url: "https://meet.example.com/room/123456789"
        )

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: video_integration.id
        )

      TestMocks.setup_all_mocks()

      assert {:ok, %MeetingSchema{} = updated_meeting} =
               Meetings.add_video_room_to_meeting(meeting.id)

      assert updated_meeting.video_room_id != nil
      assert updated_meeting.video_room_enabled == true
    end

    test "returns error for unknown video provider" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      # Insert a video integration with an invalid provider directly into the DB
      # (bypassing changeset validation)
      {:ok, video_integration} =
        Repo.insert(%VideoIntegrationSchema{
          user_id: user.id,
          name: "Invalid Provider",
          provider: "invalid_provider",
          is_active: true
        })

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: video_integration.id
        )

      TestMocks.setup_all_mocks()

      assert {:error, :unknown_provider} = Meetings.add_video_room_to_meeting(meeting.id)
    end

    test "returns error when video integration is inactive" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      video_integration =
        insert(:video_integration, user: user, provider: "mirotalk", is_active: false)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: video_integration.id
        )

      TestMocks.setup_all_mocks()

      assert {:error, :video_integration_inactive} =
               Meetings.add_video_room_to_meeting(meeting.id)
    end
  end

  describe "cancel_meeting/1" do
    test "cancels a future meeting by uid" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      assert {:ok, cancelled_meeting} = Meetings.cancel_meeting(meeting.uid)
      assert cancelled_meeting.status == "cancelled"
    end

    test "returns error for non-existent meeting" do
      assert {:error, :meeting_not_found} = Meetings.cancel_meeting("non-existent-uid")
    end
  end

  describe "send_reschedule_request/1" do
    test "successfully processes reschedule request" do
      meeting = insert(:meeting, status: "confirmed")

      assert :ok = Meetings.send_reschedule_request(meeting)

      # Verify status updated
      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.status == "reschedule_requested"
    end

    test "returns error when policy blocks reschedule" do
      # Create a meeting in the past which shouldn't be reschedulable by default policy
      meeting =
        insert(:meeting,
          status: "confirmed",
          start_time: DateTime.add(DateTime.utc_now(), -3600),
          end_time: DateTime.add(DateTime.utc_now(), -1800)
        )

      assert {:error, "Cannot reschedule a meeting that has already occurred"} =
               Meetings.send_reschedule_request(meeting)
    end
  end

  describe "list_user_meetings_by_filter/3" do
    test "returns upcoming meetings for user" do
      %{user: user} = create_user_with_profile()
      insert_meeting_for_user(user)

      assert {:ok, page} = Meetings.list_user_meetings_by_filter(user.id, "upcoming")
      assert length(page.items) == 1
    end

    test "returns error for invalid cursor" do
      %{user: user} = create_user_with_profile()

      assert {:error, :invalid_cursor} =
               Meetings.list_user_meetings_by_filter(user.id, "upcoming", after: "invalid")
    end
  end

  describe "get_meeting/1" do
    test "returns meeting when it exists" do
      meeting = insert(:meeting)
      assert {:ok, result} = Meetings.get_meeting(meeting.id)
      assert result.id == meeting.id
    end

    test "returns :not_found when meeting does not exist" do
      assert {:error, :not_found} = Meetings.get_meeting(UUID.generate())
    end
  end

  describe "list_user_meetings_cursor_page/2" do
    shared_cursor_pagination_tests()
  end

  describe "list_user_meetings_cursor_page_by_id/2" do
    test "returns meetings for valid user id" do
      %{user: user} = create_user_with_profile()

      insert_meeting_for_user(user)

      assert {:ok, page} = Meetings.list_user_meetings_cursor_page_by_id(user.id)

      assert length(page.items) == 1
    end

    test "returns empty page for non-existent user" do
      non_existent_id = 999_999_999

      assert {:ok, page} = Meetings.list_user_meetings_cursor_page_by_id(non_existent_id)

      assert page.items == []
      assert page.has_more == false
    end
  end
end
