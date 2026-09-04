defmodule Tymeslot.Meetings.MeetingStateTest do
  @moduledoc """
  Unit tests for the meeting-state predicates, including the legacy
  `status == "reschedule_requested"` value the moduledoc claims to keep
  reading correctly.
  """

  use ExUnit.Case, async: true

  @moduletag :meetings
  @moduletag :unit

  alias Tymeslot.Meetings.MeetingState

  describe "active?/1" do
    test "true for confirmed and pending meetings" do
      assert MeetingState.active?(%{status: "confirmed"})
      assert MeetingState.active?(%{status: "pending"})
    end

    test "true for the legacy reschedule_requested status" do
      assert MeetingState.active?(%{status: "reschedule_requested"})
    end

    test "false for cancelled, completed, awaiting_payment, and expired" do
      refute MeetingState.active?(%{status: "cancelled"})
      refute MeetingState.active?(%{status: "completed"})
      refute MeetingState.active?(%{status: "awaiting_payment"})
      refute MeetingState.active?(%{status: "expired"})
    end
  end

  describe "awaiting_approval?/1" do
    test "true only for the held status" do
      assert MeetingState.awaiting_approval?(%{status: "awaiting_approval"})

      refute MeetingState.awaiting_approval?(%{status: "confirmed"})
      refute MeetingState.awaiting_approval?(%{status: "pending"})
      refute MeetingState.awaiting_approval?(%{status: "awaiting_payment"})
    end

    test "a held request is active, so the invitee may still cancel or move it" do
      assert MeetingState.active?(%{status: "awaiting_approval"})
    end

    test "a held request expects a calendar event, because a tentative one is written" do
      assert MeetingState.expects_calendar_event?(%{
               status: "awaiting_approval",
               reschedule_requested_at: nil
             })
    end

    test "a held request is not awaiting a new time from the attendee" do
      refute MeetingState.awaiting_new_time?(%{
               status: "awaiting_approval",
               reschedule_requested_at: nil
             })
    end
  end

  describe "slot_void?/1" do
    test "true when cancelled, regardless of reschedule_requested_at" do
      assert MeetingState.slot_void?(%{status: "cancelled", reschedule_requested_at: nil})
    end

    test "true for the legacy reschedule_requested status" do
      assert MeetingState.slot_void?(%{
               status: "reschedule_requested",
               reschedule_requested_at: nil
             })
    end

    test "true when an organizer reschedule request is pending" do
      assert MeetingState.slot_void?(%{
               status: "confirmed",
               reschedule_requested_at: DateTime.utc_now()
             })
    end

    test "false for a live meeting with no pending request" do
      refute MeetingState.slot_void?(%{status: "confirmed", reschedule_requested_at: nil})
      refute MeetingState.slot_void?(%{status: "pending", reschedule_requested_at: nil})
    end
  end

  describe "expects_calendar_event?/1" do
    test "true for a plain confirmed meeting with no pending reschedule request" do
      assert MeetingState.expects_calendar_event?(%{
               status: "confirmed",
               reschedule_requested_at: nil
             })
    end

    test "false when a reschedule request is pending, even though the meeting is active" do
      refute MeetingState.expects_calendar_event?(%{
               status: "confirmed",
               reschedule_requested_at: DateTime.utc_now()
             })
    end

    test "false for the legacy reschedule_requested status" do
      refute MeetingState.expects_calendar_event?(%{
               status: "reschedule_requested",
               reschedule_requested_at: nil
             })
    end

    test "false for cancelled, completed, and awaiting_payment meetings" do
      refute MeetingState.expects_calendar_event?(%{
               status: "cancelled",
               reschedule_requested_at: nil
             })

      refute MeetingState.expects_calendar_event?(%{
               status: "completed",
               reschedule_requested_at: nil
             })

      refute MeetingState.expects_calendar_event?(%{
               status: "awaiting_payment",
               reschedule_requested_at: nil
             })
    end
  end

  describe "awaiting_new_time?/1" do
    test "true when reschedule_requested_at is set" do
      assert MeetingState.awaiting_new_time?(%{
               status: "confirmed",
               reschedule_requested_at: DateTime.utc_now()
             })
    end

    test "true for the legacy reschedule_requested status, even without the timestamp" do
      assert MeetingState.awaiting_new_time?(%{
               status: "reschedule_requested",
               reschedule_requested_at: nil
             })
    end

    test "false for a meeting with no pending request" do
      refute MeetingState.awaiting_new_time?(%{status: "confirmed", reschedule_requested_at: nil})
    end
  end
end
