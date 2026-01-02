defmodule Tymeslot.Bookings.RescheduleTest do
  @moduledoc """
  Tests for the booking rescheduling module.
  """

  use Tymeslot.DataCase, async: true

  import Mox

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.TestMocks
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup do
    # Setup mocks for calendar and email services
    TestMocks.setup_email_mocks()
    :ok
  end

  defp setup_reschedule_test do
    %{user: user, profile: profile} = create_user_with_profile()
    meeting = insert_meeting_for_user(user)

    # Create new params for rescheduling (2 days from now instead of 1)
    new_date = Date.add(Date.utc_today(), 2)

    new_params = %{
      date: Date.to_string(new_date),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }

    %{user: user, profile: profile, meeting: meeting, new_params: new_params}
  end

  describe "execute/3 - successful rescheduling" do
    test "successfully reschedules a future meeting" do
      %{meeting: meeting, new_params: new_params} = setup_reschedule_test()

      assert {:ok, updated_meeting} = Reschedule.execute(meeting.uid, new_params, %{})

      # Verify the meeting was updated
      assert updated_meeting.id == meeting.id
      # The new start time should be different from the original
      refute DateTime.compare(updated_meeting.start_time, meeting.start_time) == :eq
    end

    test "updates meeting times correctly" do
      %{meeting: meeting, new_params: new_params} = setup_reschedule_test()

      assert {:ok, updated_meeting} = Reschedule.execute(meeting.uid, new_params, %{})

      # Reload from database to verify persistence
      {:ok, reloaded} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert DateTime.compare(reloaded.start_time, updated_meeting.start_time) == :eq
      assert DateTime.compare(reloaded.end_time, updated_meeting.end_time) == :eq
    end
  end

  describe "execute/3 - meeting not found" do
    test "returns error when meeting does not exist" do
      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Original meeting not found"} =
               Reschedule.execute("non-existent-uid", new_params, %{})
    end
  end

  describe "execute/3 - policy violations" do
    test "returns error when meeting is already cancelled" do
      %{meeting: meeting, new_params: new_params} = setup_reschedule_test()

      # Update meeting to cancelled status
      {:ok, _} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})

      assert {:error, "Cannot reschedule a cancelled meeting"} =
               Reschedule.execute(meeting.uid, new_params, %{})
    end

    test "returns error when meeting is completed" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -7_200,
          duration: 3_600
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Cannot reschedule a completed meeting"} =
               Reschedule.execute(meeting.uid, new_params, %{})
    end

    test "returns error when meeting has already started" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -3_600,
          duration: 7_200
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Cannot reschedule a meeting that has already started"} =
               Reschedule.execute(meeting.uid, new_params, %{})
    end

    test "returns error when meeting has already occurred" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -7_200,
          duration: 3_600
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Cannot reschedule a meeting that has already occurred"} =
               Reschedule.execute(meeting.uid, new_params, %{})
    end
  end

  describe "execute/3 - validation errors" do
    test "returns error with invalid date format" do
      %{meeting: meeting} = setup_reschedule_test()

      invalid_params = %{
        date: "not-a-date",
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Invalid date or time format"} =
               Reschedule.execute(meeting.uid, invalid_params, %{})
    end

    test "returns error with invalid time format" do
      %{meeting: meeting} = setup_reschedule_test()

      invalid_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "invalid-time",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Invalid date or time format"} =
               Reschedule.execute(meeting.uid, invalid_params, %{})
    end

    test "returns error when rescheduling to a past date" do
      %{meeting: meeting} = setup_reschedule_test()

      past_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), -1)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      # Should fail with some form of time validation error
      assert {:error, _reason} = Reschedule.execute(meeting.uid, past_params, %{})
    end
  end

  describe "execute/3 - edge cases" do
    test "allows rescheduling meeting that starts soon" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 600,
          duration: 3_600
        })

      # Reschedule to 2 days from now
      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:ok, updated_meeting} = Reschedule.execute(meeting.uid, new_params, %{})
      assert updated_meeting.id == meeting.id
    end

    test "handles different duration formats" do
      %{meeting: meeting} = setup_reschedule_test()

      # Using 30min duration instead of 60min
      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "3:00 PM",
        duration: "30min",
        user_timezone: "America/New_York"
      }

      assert {:ok, updated_meeting} = Reschedule.execute(meeting.uid, new_params, %{})
      assert updated_meeting.id == meeting.id
    end

    test "handles different timezone" do
      %{meeting: meeting} = setup_reschedule_test()

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "10:00 AM",
        duration: "60min",
        user_timezone: "Europe/London"
      }

      assert {:ok, updated_meeting} = Reschedule.execute(meeting.uid, new_params, %{})
      assert updated_meeting.id == meeting.id
    end
  end
end
