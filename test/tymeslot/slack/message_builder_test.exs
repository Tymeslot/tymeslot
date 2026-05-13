defmodule Tymeslot.Slack.MessageBuilderTest do
  use ExUnit.Case, async: true

  @moduletag :slack
  @moduletag :unit

  alias Tymeslot.Slack.MessageBuilder

  @meeting %{
    attendee_name: "John Smith",
    attendee_email: "john@example.com",
    attendee_timezone: "UTC",
    start_time: ~U[2026-03-10 14:00:00Z],
    end_time: ~U[2026-03-10 14:30:00Z],
    event_type: %{name: "30-minute intro call"},
    uid: "abc123",
    cancellation_reason: nil
  }

  describe "build_blocks/2 — meeting.created" do
    test "includes a header block, summary, details, and an action button" do
      blocks = MessageBuilder.build_blocks("meeting.created", @meeting)

      assert [
               %{"type" => "header", "text" => %{"text" => "New booking"}},
               %{"type" => "section"},
               %{"type" => "divider"},
               %{"type" => "section"},
               %{"type" => "actions"}
             ] = Enum.map(blocks, &Map.take(&1, ["type", "text"]))

      json = Jason.encode!(blocks)
      assert json =~ "John Smith"
      assert json =~ "john@example.com"
      assert json =~ "14:00"
      assert json =~ "14:30"
      assert json =~ "Open in Tymeslot"
      assert json =~ "Meeting"
    end
  end

  describe "build_blocks/2 — meeting.cancelled" do
    test "includes the cancellation reason in a quote block" do
      meeting = %{@meeting | cancellation_reason: "Schedule conflict"}
      blocks = MessageBuilder.build_blocks("meeting.cancelled", meeting)
      json = Jason.encode!(blocks)
      assert json =~ "Booking cancelled"
      assert json =~ "Schedule conflict"
      assert json =~ ">Schedule conflict"
    end

    test "falls back to 'No reason given' when cancellation_reason is missing" do
      blocks = MessageBuilder.build_blocks("meeting.cancelled", @meeting)
      assert Jason.encode!(blocks) =~ "No reason given"
    end

    test "truncates cancellation reasons longer than 500 chars with ellipsis" do
      long_reason = String.duplicate("a", 600)
      meeting = %{@meeting | cancellation_reason: long_reason}
      blocks = MessageBuilder.build_blocks("meeting.cancelled", meeting)
      json = Jason.encode!(blocks)
      assert json =~ "aaa..."
      refute String.contains?(json, String.duplicate("a", 600))
    end
  end

  describe "build_blocks/2 — meeting.rescheduled" do
    test "includes the new time and an action button" do
      blocks = MessageBuilder.build_blocks("meeting.rescheduled", @meeting)
      json = Jason.encode!(blocks)
      assert json =~ "Booking rescheduled"
      assert json =~ "New time"
      assert json =~ "14:00"
      assert json =~ "Open in Tymeslot"
    end
  end

  describe "escaping" do
    test "escapes Slack mrkdwn special characters in attendee_name" do
      meeting = %{@meeting | attendee_name: "<script>alert('xss')</script>"}
      blocks = MessageBuilder.build_blocks("meeting.created", meeting)
      json = Jason.encode!(blocks)
      refute json =~ "<script>"
      assert json =~ "&lt;script&gt;"
    end

    test "falls back to attendee_email when attendee_name is nil" do
      meeting = %{@meeting | attendee_name: nil}
      blocks = MessageBuilder.build_blocks("meeting.created", meeting)
      assert Jason.encode!(blocks) =~ "john@example.com"
    end
  end

  describe "build_test_blocks/0" do
    test "returns a header + section block referencing Tymeslot" do
      blocks = MessageBuilder.build_test_blocks()
      json = Jason.encode!(blocks)
      assert json =~ "Tymeslot test message"
      assert json =~ "configured correctly"
    end
  end
end
