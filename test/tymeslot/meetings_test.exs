defmodule Tymeslot.MeetingsTest do
  @moduledoc """
  Tests for the Meetings context module.
  """

  use Tymeslot.DataCase, async: true

  import Mox

  alias Ecto.UUID
  alias Tymeslot.Meetings
  alias Tymeslot.TestMocks
  import Tymeslot.MeetingTestHelpers
  import Tymeslot.CursorPaginationTestCases

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  describe "parse_duration_minutes/1" do
    test "parses 15min duration" do
      assert Meetings.parse_duration_minutes("15min") == 15
    end

    test "parses 30min duration" do
      assert Meetings.parse_duration_minutes("30min") == 30
    end

    test "defaults to 30 for unknown duration" do
      assert Meetings.parse_duration_minutes("60min") == 30
      assert Meetings.parse_duration_minutes("unknown") == 30
      assert Meetings.parse_duration_minutes("") == 30
    end
  end

  describe "parse_time_slot/1" do
    test "parses 12-hour time format with AM" do
      result = Meetings.parse_time_slot("9:00 AM")
      assert %Time{hour: 9, minute: 0} = result
    end

    test "parses 12-hour time format with PM" do
      result = Meetings.parse_time_slot("2:30 PM")
      assert %Time{hour: 14, minute: 30} = result
    end

    test "parses noon correctly" do
      result = Meetings.parse_time_slot("12:00 PM")
      assert %Time{hour: 12, minute: 0} = result
    end

    test "parses midnight correctly" do
      result = Meetings.parse_time_slot("12:00 AM")
      assert %Time{hour: 0, minute: 0} = result
    end
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
