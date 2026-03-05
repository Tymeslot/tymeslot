defmodule Tymeslot.Telegram.MessageBuilderTest do
  use Tymeslot.DataCase, async: true

  @moduletag :telegram
  @moduletag :unit

  alias Tymeslot.Telegram.MessageBuilder

  @meeting %{
    attendee_name: "John Smith",
    attendee_email: "john@example.com",
    attendee_timezone: "UTC",
    start_time: ~U[2026-03-10 14:00:00Z],
    end_time: ~U[2026-03-10 14:30:00Z],
    event_type: %{name: "30-minute intro call"},
    uid: "abc123",
    video_room_url: nil,
    cancellation_reason: nil
  }

  describe "build_message/2" do
    test "builds meeting.created message" do
      msg = MessageBuilder.build_message("meeting.created", @meeting)
      assert msg =~ "<b>New Meeting</b>"
      assert msg =~ "John Smith"
      assert msg =~ "Meeting"
      assert msg =~ "john@example.com"
      assert msg =~ "14:00"
    end

    test "builds meeting.cancelled message" do
      meeting = Map.put(@meeting, :cancellation_reason, "Schedule conflict")
      msg = MessageBuilder.build_message("meeting.cancelled", meeting)
      assert msg =~ "<b>Meeting Cancelled</b>"
      assert msg =~ "John Smith"
      assert msg =~ "Schedule conflict"
    end

    test "builds meeting.rescheduled message" do
      msg = MessageBuilder.build_message("meeting.rescheduled", @meeting)
      assert msg =~ "<b>Meeting Rescheduled</b>"
      assert msg =~ "John Smith"
    end

    test "HTML-escapes user content" do
      meeting = %{@meeting | attendee_name: "<script>alert('xss')</script>"}
      msg = MessageBuilder.build_message("meeting.created", meeting)
      refute msg =~ "<script>"
      assert msg =~ "&lt;script&gt;"
    end

    test "includes video link when present" do
      meeting = Map.put(@meeting, :video_room_url, "https://meet.example.com/room")
      msg = MessageBuilder.build_message("meeting.created", meeting)
      assert msg =~ "Join video call"
      assert msg =~ "https://meet.example.com/room"
    end

    test "uses attendee_email as fallback name" do
      meeting = %{@meeting | attendee_name: nil}
      msg = MessageBuilder.build_message("meeting.created", meeting)
      assert msg =~ "john@example.com"
    end
  end

  describe "build_test_message/0" do
    test "returns a test message" do
      msg = MessageBuilder.build_test_message()
      assert msg =~ "Test"
      assert msg =~ "Tymeslot"
    end
  end
end
