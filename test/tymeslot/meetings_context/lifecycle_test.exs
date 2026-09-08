defmodule Tymeslot.MeetingsContext.LifecycleTest do
  @moduledoc """
  Behaviour tests for the Meetings context covering appointment lifecycle:
  calendar-validation booking, cancellation, and rescheduling.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  import Mox

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings
  alias Tymeslot.TestMocks
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    :ok
  end

  describe "when creating appointment with calendar validation" do
    setup do
      # `build_meeting_params/1` books mid-afternoon, so the host must offer
      # that hour: booking creation refuses a time the schedule never offers.
      %{user: user, profile: profile} = create_always_bookable_profile()

      %{user: user, profile: profile}
    end

    test "succeeds when time slot is available", %{user: user} do
      meeting_params = build_meeting_params(user, %{date: Date.add(Date.utc_today(), 5)})
      form_data = build_form_data()

      assert {:ok, meeting} =
               Create.execute(meeting_params, form_data)

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

      result = Create.execute(meeting_params, form_data)

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
      %{user: user} = create_always_bookable_profile()
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
