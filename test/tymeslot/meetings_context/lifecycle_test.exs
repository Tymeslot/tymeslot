defmodule Tymeslot.MeetingsContext.LifecycleTest do
  @moduledoc """
  Behaviour tests for the Meetings context covering appointment lifecycle:
  creation, calendar-validation booking, cancellation, and rescheduling.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  import Mox

  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    :ok
  end

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

      {:ok, retrieved} = MeetingQueries.get_meeting_by_uid(meeting.uid)
      assert retrieved.id == meeting.id
      assert retrieved.attendee_email == form_data["email"]
    end

    test "appointment generates unique meeting UID", %{user: user} do
      meeting_params1 =
        build_meeting_params(user, %{date: Date.add(Date.utc_today(), 10), time: "10:00"})

      meeting_params2 =
        build_meeting_params(user, %{date: Date.add(Date.utc_today(), 11), time: "10:00"})

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

      meeting_params =
        build_meeting_params(user, %{
          date: booking_date,
          time: "14:00"
        })

      form_data = build_form_data()

      result = Meetings.create_appointment_with_validation(meeting_params, form_data)

      assert {:error, _reason} = result
    end
  end

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

      assert {:ok, rescheduled} =
               Meetings.reschedule_meeting(meeting.uid, new_params, form_data, user.id)

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

      assert {:error, _reason} =
               Meetings.reschedule_meeting(meeting.uid, new_params, form_data, user.id)
    end
  end
end
