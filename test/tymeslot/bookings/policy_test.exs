defmodule Tymeslot.Bookings.PolicyTest do
  use Tymeslot.DataCase, async: true
  @moduletag :bookings

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings.MeetingSchema

  describe "can_cancel_meeting?/1" do
    test "allows cancellation for future meetings" do
      future_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :confirmed,
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
        status: :confirmed,
        # 30 minutes ago
        start_time: DateTime.add(DateTime.utc_now(), -1800, :second),
        # 30 minutes from now
        end_time: DateTime.add(DateTime.utc_now(), 1800, :second)
      }

      assert {:error, {:not_cancellable, :started}} =
               Policy.can_cancel_meeting?(current_meeting)
    end

    test "blocks cancellation for past meetings" do
      past_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :confirmed,
        # 2 hours ago
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        # 1 hour ago
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert {:error, {:not_cancellable, :past}} =
               Policy.can_cancel_meeting?(past_meeting)
    end

    test "blocks cancellation for already cancelled meetings" do
      cancelled_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :cancelled,
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert {:error, :already_cancelled} =
               Policy.can_cancel_meeting?(cancelled_meeting)
    end

    test "blocks cancellation for completed meetings" do
      completed_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :completed,
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert {:error, {:not_cancellable, :completed}} =
               Policy.can_cancel_meeting?(completed_meeting)
    end

    test "allows cancellation for meeting starting in 1 minute" do
      # Meeting starts in exactly 1 minute - should still be allowed
      almost_starting = %MeetingSchema{
        uid: "test-uid",
        status: :confirmed,
        # 1 minute from now
        start_time: DateTime.add(DateTime.utc_now(), 60, :second),
        # 61 minutes from now
        end_time: DateTime.add(DateTime.utc_now(), 3660, :second)
      }

      assert Policy.can_cancel_meeting?(almost_starting) == :ok
    end

    test "blocks cancellation for expired meetings" do
      # A lapsed approval request. It was already released and refunded, and
      # the withdraw link in the request-received email still points here —
      # cancelling would overwrite the expiry outcome and send a second,
      # contradicting round of emails.
      expired_request = %MeetingSchema{
        uid: "test-uid",
        status: :expired,
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert {:error, {:not_cancellable, :expired}} =
               Policy.can_cancel_meeting?(expired_request)
    end
  end

  describe "can_reschedule_meeting?/1" do
    test "allows rescheduling for future meetings" do
      future_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :confirmed,
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert Policy.can_reschedule_meeting?(future_meeting) == :ok
    end

    test "blocks rescheduling for meetings that have started" do
      current_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :confirmed,
        start_time: DateTime.add(DateTime.utc_now(), -1800, :second),
        end_time: DateTime.add(DateTime.utc_now(), 1800, :second)
      }

      assert {:error, {:not_reschedulable, :started}} =
               Policy.can_reschedule_meeting?(current_meeting)
    end

    test "blocks rescheduling for past meetings" do
      past_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :confirmed,
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert {:error, {:not_reschedulable, :past}} =
               Policy.can_reschedule_meeting?(past_meeting)
    end

    test "blocks rescheduling for cancelled meetings" do
      cancelled_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :cancelled,
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert {:error, {:not_reschedulable, :cancelled}} =
               Policy.can_reschedule_meeting?(cancelled_meeting)
    end

    test "blocks rescheduling for completed meetings" do
      completed_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :completed,
        start_time: DateTime.add(DateTime.utc_now(), -7200, :second),
        end_time: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      assert {:error, {:not_reschedulable, :completed}} =
               Policy.can_reschedule_meeting?(completed_meeting)
    end

    test "blocks rescheduling for expired meetings" do
      # An expired meeting no longer occupies its slot, so moving it would hand
      # the attendee a time nothing reserves.
      expired_meeting = %MeetingSchema{
        uid: "test-uid",
        status: :expired,
        start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        end_time: DateTime.add(DateTime.utc_now(), 7200, :second)
      }

      assert {:error, {:not_reschedulable, :expired}} =
               Policy.can_reschedule_meeting?(expired_meeting)
    end

    test "allows rescheduling for meeting starting in 1 minute" do
      # Meeting starts in exactly 1 minute - should still be allowed
      almost_starting = %MeetingSchema{
        uid: "test-uid",
        status: :confirmed,
        start_time: DateTime.add(DateTime.utc_now(), 60, :second),
        end_time: DateTime.add(DateTime.utc_now(), 3660, :second)
      }

      assert Policy.can_reschedule_meeting?(almost_starting) == :ok
    end
  end

  describe "can_booker_move_meeting?/1" do
    test "refuses a meeting its host manages" do
      assert Policy.can_booker_move_meeting?(%MeetingSchema{managed_by_host: true}) ==
               {:error, :managed_by_host}
    end

    test "allows a meeting with a booker" do
      assert Policy.can_booker_move_meeting?(%MeetingSchema{managed_by_host: false}) == :ok
    end
  end

  describe "can_request_reschedule?/1" do
    test "refuses a meeting its host manages, whatever its state" do
      future = DateTime.add(DateTime.utc_now(), 7200, :second)

      for status <- [:confirmed, :awaiting_approval] do
        meeting = %{
          status: status,
          managed_by_host: true,
          start_time: future,
          end_time: DateTime.add(future, 1800, :second)
        }

        assert Policy.can_request_reschedule?(meeting) == {:error, :managed_by_host}
      end
    end

    test "still refuses a held request for a meeting with a booker" do
      assert Policy.can_request_reschedule?(%{
               status: :awaiting_approval,
               managed_by_host: false
             }) ==
               {:error, {:not_reschedulable, :awaiting_approval}}
    end
  end

  describe "can_host_change_time?/1" do
    setup do
      start_time = DateTime.add(DateTime.utc_now(), 7200, :second)
      %{start_time: start_time, end_time: DateTime.add(start_time, 1800, :second)}
    end

    test "lets the host move an upcoming meeting they manage", times do
      meeting = Map.merge(times, %{status: :confirmed, managed_by_host: true})

      assert Policy.can_host_change_time?(meeting) == :ok
    end

    test "refuses the host a meeting they manage once it has ended" do
      ended = DateTime.add(DateTime.utc_now(), -3600, :second)

      meeting = %{
        status: :confirmed,
        managed_by_host: true,
        start_time: DateTime.add(ended, -1800, :second),
        end_time: ended
      }

      assert {:error, _reason} = Policy.can_host_change_time?(meeting)
    end

    test "asks the attendee of a booked meeting, refusing a fixed date", times do
      booked = Map.merge(times, %{status: :confirmed, managed_by_host: false})

      assert Policy.can_host_change_time?(booked) == :ok

      assert Policy.can_host_change_time?(Map.put(booked, :planned, true)) ==
               {:error, {:not_reschedulable, :planned}}
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
