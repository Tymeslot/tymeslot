defmodule Tymeslot.Bookings.PolicyTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.DatabaseSchemas.MeetingSchema

  describe "can_cancel_meeting?/1" do
    test "allows cancellation for future meetings" do
      future_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "confirmed",
        # 1 hour from now
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        # 2 hours from now
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert Policy.can_cancel_meeting?(future_meeting) == :ok
    end

    test "blocks cancellation for meetings that have started" do
      current_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "confirmed",
        # 30 minutes ago
        start_time: DateTime.add(DateTime.utc_now(), -1800, :second),
        # 30 minutes from now
        end_time: DateTime.add(DateTime.utc_now(), 1800, :second)
      }

      assert {:error, "Cannot cancel a meeting that has already started"} =
               Policy.can_cancel_meeting?(current_meeting)
    end

    test "blocks cancellation for past meetings" do
      past_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "confirmed",
        # 2 hours ago
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        # 1 hour ago
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert {:error, "Cannot cancel a meeting that has already occurred"} =
               Policy.can_cancel_meeting?(past_meeting)
    end

    test "blocks cancellation for already cancelled meetings" do
      cancelled_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "cancelled",
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert {:error, "Meeting is already cancelled"} =
               Policy.can_cancel_meeting?(cancelled_meeting)
    end

    test "blocks cancellation for completed meetings" do
      completed_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "completed",
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert {:error, "Cannot cancel a completed meeting"} =
               Policy.can_cancel_meeting?(completed_meeting)
    end

    test "allows cancellation for meeting starting in 1 minute" do
      # Meeting starts in exactly 1 minute - should still be allowed
      almost_starting = %MeetingSchema{
        uid: "test-uid",
        status: "confirmed",
        # 1 minute from now
        start_time: DateTime.add(DateTime.utc_now(), 60, :second),
        # 61 minutes from now
        end_time: DateTime.add(DateTime.utc_now(), 3660, :second)
      }

      assert Policy.can_cancel_meeting?(almost_starting) == :ok
    end
  end

  describe "can_reschedule_meeting?/1" do
    test "allows rescheduling for future meetings" do
      future_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "confirmed",
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert Policy.can_reschedule_meeting?(future_meeting) == :ok
    end

    test "blocks rescheduling for meetings that have started" do
      current_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "confirmed",
        start_time: DateTime.add(DateTime.utc_now(), -1800, :second),
        end_time: DateTime.add(DateTime.utc_now(), 1800, :second)
      }

      assert {:error, "Cannot reschedule a meeting that has already started"} =
               Policy.can_reschedule_meeting?(current_meeting)
    end

    test "blocks rescheduling for past meetings" do
      past_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "confirmed",
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert {:error, "Cannot reschedule a meeting that has already occurred"} =
               Policy.can_reschedule_meeting?(past_meeting)
    end

    test "blocks rescheduling for cancelled meetings" do
      cancelled_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "cancelled",
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert {:error, "Cannot reschedule a cancelled meeting"} =
               Policy.can_reschedule_meeting?(cancelled_meeting)
    end

    test "blocks rescheduling for completed meetings" do
      completed_meeting = %MeetingSchema{
        uid: "test-uid",
        status: "completed",
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert {:error, "Cannot reschedule a completed meeting"} =
               Policy.can_reschedule_meeting?(completed_meeting)
    end

    test "allows rescheduling for meeting starting in 1 minute" do
      # Meeting starts in exactly 1 minute - should still be allowed
      almost_starting = %MeetingSchema{
        uid: "test-uid",
        status: "confirmed",
        start_time: DateTime.add(DateTime.utc_now(), 60, :second),
        end_time: DateTime.add(DateTime.utc_now(), 3660, :second)
      }

      assert Policy.can_reschedule_meeting?(almost_starting) == :ok
    end
  end

  describe "meeting_is_current?/1" do
    test "returns true for ongoing meeting" do
      current_meeting = %{
        start_time: DateTime.add(DateTime.utc_now(), -1800, :second),
        end_time: DateTime.add(DateTime.utc_now(), 1800, :second)
      }

      assert Policy.meeting_is_current?(current_meeting) == true
    end

    test "returns false for future meeting" do
      future_meeting = %{
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert Policy.meeting_is_current?(future_meeting) == false
    end

    test "returns false for past meeting" do
      past_meeting = %{
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert Policy.meeting_is_current?(past_meeting) == false
    end

    test "returns true for meeting that just started" do
      just_started = %{
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Policy.meeting_is_current?(just_started) == true
    end
  end

  describe "meeting_is_past?/1" do
    test "returns true for past meeting" do
      past_meeting = %{
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert Policy.meeting_is_past?(past_meeting) == true
    end

    test "returns false for future meeting" do
      future_meeting = %{
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Policy.meeting_is_past?(future_meeting) == false
    end

    test "returns false for ongoing meeting" do
      current_meeting = %{
        end_time: DateTime.add(DateTime.utc_now(), 1800, :second)
      }

      assert Policy.meeting_is_past?(current_meeting) == false
    end

    test "returns false for meeting ending soon" do
      # Use a larger future offset (30 seconds) to avoid timing issues in tests
      ending_soon = %{
        end_time: DateTime.add(DateTime.utc_now(), 30, :second)
      }

      # Meeting ending in 30 seconds is not considered past
      assert Policy.meeting_is_past?(ending_soon) == false
    end
  end
end
