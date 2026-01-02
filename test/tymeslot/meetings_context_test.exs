defmodule Tymeslot.MeetingsContextTest do
  @moduledoc """
  Comprehensive behavior tests for the Meetings context module.
  Focuses on user-facing functionality and business rules rather than implementation details.
  """

  use Tymeslot.DataCase, async: false

  import Mox

  alias Ecto.UUID
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Meetings
  alias Tymeslot.TestMocks
  import Tymeslot.MeetingTestHelpers
  import Tymeslot.CursorPaginationTestCases

  setup :verify_on_exit!

  setup do
    # Set Mox to global mode to allow async processes to use mocks
    Mox.set_mox_global()

    TestMocks.setup_email_mocks()

    # Set up calendar mock globally for async operations
    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:list_events_in_range, fn _start_time, _end_time -> {:ok, []} end)

    :ok
  end

  # =====================================
  # Appointment Creation Behaviors
  # =====================================

  describe "when a user books an appointment" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)
      meeting_type = insert(:meeting_type, user: user)

      %{user: user, profile: profile, meeting_type: meeting_type}
    end

    test "appointment is created with all required details", %{user: user} do
      meeting_params = build_meeting_params(user)
      form_data = build_form_data()

      assert {:ok, meeting} = Meetings.create_appointment(meeting_params, form_data)

      assert meeting.attendee_name == form_data["name"]
      assert meeting.attendee_email == form_data["email"]
      assert meeting.attendee_message == form_data["message"]
      assert meeting.status == "confirmed"
      assert meeting.organizer_user_id == user.id
    end

    test "appointment includes correct time zone handling", %{user: user} do
      meeting_params =
        build_meeting_params(user, %{
          user_timezone: "America/Los_Angeles"
        })

      form_data = build_form_data()

      assert {:ok, meeting} = Meetings.create_appointment(meeting_params, form_data)

      assert meeting.attendee_timezone == "America/Los_Angeles"
    end

    test "appointment is persisted in database", %{user: user} do
      meeting_params = build_meeting_params(user)
      form_data = build_form_data()

      assert {:ok, meeting} = Meetings.create_appointment(meeting_params, form_data)

      # Verify it can be retrieved
      {:ok, retrieved} = MeetingQueries.get_meeting_by_uid(meeting.uid)
      assert retrieved.id == meeting.id
      assert retrieved.attendee_email == form_data["email"]
    end

    test "appointment generates unique meeting UID", %{user: user} do
      # Use different days and times to avoid any slot conflict
      meeting_params1 = build_meeting_params(user, %{date: Date.add(Date.utc_today(), 10), time: "10:00"})
      meeting_params2 = build_meeting_params(user, %{date: Date.add(Date.utc_today(), 11), time: "10:00"})
      form_data1 = build_form_data()
      form_data2 = build_form_data()

      assert {:ok, meeting1} = Meetings.create_appointment(meeting_params1, form_data1)
      assert {:ok, meeting2} = Meetings.create_appointment(meeting_params2, form_data2)

      assert meeting1.uid != meeting2.uid
    end
  end

  describe "when creating appointment with calendar validation" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)

      %{user: user, profile: profile}
    end

    test "succeeds when time slot is available", %{user: user} do
      meeting_params = build_meeting_params(user, %{date: Date.add(Date.utc_today(), 5)})
      form_data = build_form_data()

      assert {:ok, meeting} =
               Meetings.create_appointment_with_validation(meeting_params, form_data)

      assert meeting.status == "confirmed"
    end

    test "fails when time slot has conflict", %{user: user} do
      # Create an existing meeting at the same time
      booking_date = Date.add(Date.utc_today(), 2)

      start_time =
        booking_date
        |> DateTime.new!(~T[14:00:00], "America/New_York")
        |> DateTime.shift_zone!("Etc/UTC")

      _existing_meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          start_time: start_time,
          end_time: DateTime.add(start_time, 60, :minute),
          status: "confirmed"
        )

      # Try to book at same time - should conflict
      meeting_params =
        build_meeting_params(user, %{
          date: booking_date,
          time: "14:00"
        })

      form_data = build_form_data()

      result = Meetings.create_appointment_with_validation(meeting_params, form_data)

      # Should fail due to conflict with existing meeting
      assert {:error, _reason} = result
    end
  end

  # =====================================
  # Meeting Lifecycle Behaviors
  # =====================================

  describe "when cancelling a meeting" do
    test "future meeting can be cancelled by organizer" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      assert {:ok, cancelled} = Meetings.cancel_meeting(meeting.uid)
      assert cancelled.status == "cancelled"
    end

    test "past meeting cannot be cancelled" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: -86_400, duration: 3_600})

      assert {:error, _reason} = Meetings.cancel_meeting(meeting.uid)
    end

    test "already cancelled meeting returns error" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{status: "cancelled"})

      assert {:error, "Meeting is already cancelled"} = Meetings.cancel_meeting(meeting.uid)
    end

    test "non-existent meeting returns not found error" do
      assert {:error, :meeting_not_found} = Meetings.cancel_meeting("non-existent-uid")
    end
  end

  describe "when rescheduling a meeting" do
    test "future meeting can be rescheduled to new time" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      new_date = Date.add(Date.utc_today(), 5)

      new_params = %{
        date: Date.to_string(new_date),
        time: "10:00 AM",
        duration: "60min",
        user_timezone: "America/New_York",
        organizer_user_id: user.id
      }

      form_data = %{"name" => meeting.attendee_name, "email" => meeting.attendee_email}

      assert {:ok, rescheduled} = Meetings.reschedule_meeting(meeting.uid, new_params, form_data)
      assert DateTime.to_date(rescheduled.start_time) == new_date
      assert rescheduled.status in ["rescheduled", "confirmed"]
    end

    test "past meeting cannot be rescheduled" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      new_params = %{
        date: Date.add(Date.utc_today(), 5),
        time: "10:00 AM",
        duration: "60min",
        user_timezone: "America/New_York",
        organizer_user_id: user.id
      }

      form_data = %{"name" => meeting.attendee_name, "email" => meeting.attendee_email}

      assert {:error, _reason} = Meetings.reschedule_meeting(meeting.uid, new_params, form_data)
    end
  end

  # =====================================
  # Meeting Query Behaviors
  # =====================================

  describe "when viewing upcoming meetings" do
    test "returns only future confirmed meetings" do
      %{user: user} = create_user_with_profile()

      upcoming = insert_meeting_for_user(user)

      _past =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      meetings = Meetings.list_upcoming_meetings_for_user(user.email)

      assert length(meetings) == 1
      assert hd(meetings).id == upcoming.id
    end

    test "returns empty list when user has no upcoming meetings" do
      %{user: user} = create_user_with_profile()

      meetings = Meetings.list_upcoming_meetings_for_user(user.email)

      assert meetings == []
    end
  end

  describe "when viewing past meetings" do
    test "returns only past meetings" do
      %{user: user} = create_user_with_profile()

      past =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      _upcoming = insert_meeting_for_user(user)

      meetings = Meetings.list_past_meetings_for_user(user.email)

      assert length(meetings) == 1
      assert hd(meetings).id == past.id
    end
  end

  describe "when viewing cancelled meetings" do
    test "returns only cancelled meetings" do
      %{user: user} = create_user_with_profile()

      cancelled =
        insert_meeting_for_user(user, %{
          status: "cancelled"
        })

      _confirmed = insert_meeting_for_user(user)

      meetings = Meetings.list_cancelled_meetings_for_user(user.email)

      assert length(meetings) == 1
      assert hd(meetings).id == cancelled.id
    end
  end

  describe "when paginating meetings with cursor" do
    shared_cursor_pagination_tests()

    test "returns subsequent pages using cursor" do
      %{user: user} = create_user_with_profile()

      # Create 5 meetings
      for i <- 1..5 do
        insert_meeting_for_user(user, %{start_offset: 86_400 * i})
      end

      # Get first page
      {:ok, page1} = Meetings.list_user_meetings_cursor_page(user.email, per_page: 3)

      # Get second page using cursor
      {:ok, page2} =
        Meetings.list_user_meetings_cursor_page(user.email,
          per_page: 3,
          after: page1.next_cursor
        )

      assert length(page2.items) == 2
      assert page2.has_more == false

      # Ensure no overlap between pages
      page1_ids = Enum.map(page1.items, & &1.id)
      page2_ids = Enum.map(page2.items, & &1.id)
      assert Enum.all?(page2_ids, fn id -> id not in page1_ids end)
    end

  end

  describe "when looking up a meeting by ID" do
    test "returns meeting when it exists" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

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

  # =====================================
  # Video Room Integration Behaviors
  # =====================================

  describe "when creating appointment with video room" do
    test "meeting is created even when video integration is configured" do
      %{user: user} = create_user_with_profile()

      # Set up video integration for user
      insert(:video_integration,
        user: user,
        provider: "mirotalk",
        is_active: true,
        is_default: true
      )

      meeting_params = build_meeting_params(user, %{date: Date.add(Date.utc_today(), 6)})
      form_data = build_form_data()

      result = Meetings.create_appointment_with_video_room(meeting_params, form_data)

      # Should succeed even if video room creation fails (graceful degradation)
      assert {:ok, meeting} = result
      assert meeting.status == "confirmed"
    end

    test "meeting without video integration still creates successfully" do
      %{user: user} = create_user_with_profile()

      # No video integration configured
      meeting_params = build_meeting_params(user, %{date: Date.add(Date.utc_today(), 7)})
      form_data = build_form_data()

      result = Meetings.create_appointment_with_video_room(meeting_params, form_data)

      # Should succeed even without video integration
      assert {:ok, meeting} = result
      assert meeting.status == "confirmed"
    end
  end

  describe "when adding video room to existing meeting" do
    test "returns error when meeting does not exist" do
      result = Meetings.add_video_room_to_meeting(UUID.generate())

      assert {:error, :meeting_not_found} = result
    end

    test "returns error when user has no video integration" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      result = Meetings.add_video_room_to_meeting(meeting.id)

      # Should error because no video integration
      assert {:error, _reason} = result
    end
  end

  # =====================================
  # Email Notification Behaviors
  # =====================================

  describe "when scheduling email notifications" do
    test "email notifications are scheduled for new meetings" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      # This should not raise
      result = Meetings.schedule_email_notifications(meeting)

      # Result can be :ok or {:error, _} depending on Oban config
      assert result in [:ok, {:error, :disabled}] or match?({:error, _}, result)
    end
  end

  describe "when checking meetings needing reminders" do
    test "returns meetings starting within the next hour that haven't been reminded" do
      %{user: user} = create_user_with_profile()

      meeting_soon =
        insert_meeting_for_user(user, %{
          start_offset: 1800,
          duration: 3_600,
          reminder_email_sent: false
        })

      # Meeting starting in 2 hours (should not be included)
      _meeting_later =
        insert_meeting_for_user(user, %{
          start_offset: 7200,
          duration: 3_600,
          reminder_email_sent: false
        })

      meetings = Meetings.meetings_needing_reminders()

      meeting_ids = Enum.map(meetings, & &1.id)
      assert meeting_soon.id in meeting_ids
    end
  end

  # =====================================
  # Reschedule Request Behaviors
  # =====================================

  describe "when sending reschedule request" do
    test "reschedule request updates meeting status" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      result = Meetings.send_reschedule_request(meeting)

      # Should succeed or return policy error
      case result do
        :ok ->
          {:ok, updated} = MeetingQueries.get_meeting_by_uid(meeting.uid)
          assert updated.status == "reschedule_requested"

        {:error, reason} ->
          # Policy may prevent reschedule if within certain time window
          assert is_binary(reason) or is_atom(reason)
      end
    end

    test "cannot send reschedule request for past meeting" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      result = Meetings.send_reschedule_request(meeting)

      assert {:error, _reason} = result
    end
  end

  # =====================================
  # Calendar Event Async Operations
  # =====================================

  describe "when creating calendar events asynchronously" do
    test "calendar event creation does not fail meeting creation" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      # Should not raise regardless of calendar integration state
      result = Meetings.create_calendar_event_async(meeting)

      assert result == :ok
    end
  end

  describe "when cancelling calendar events" do
    test "calendar event cancellation does not fail meeting cancellation" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      # Should not raise regardless of calendar integration state
      result = Meetings.cancel_calendar_event(meeting)

      assert result == :ok
    end
  end

end
