defmodule Tymeslot.Webhooks.PayloadBuilderTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Webhooks.PayloadBuilder

  describe "build_payload/3" do
    test "includes the event type, a timestamp, and webhook_id at the top level" do
      meeting = build(:meeting)
      payload = PayloadBuilder.build_payload("meeting.created", meeting, "42")

      assert payload.event == "meeting.created"
      assert is_binary(payload.timestamp)
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(payload.timestamp)
      assert payload.webhook_id == "42"
    end

    test "nests meeting data under data.meeting" do
      meeting = build(:meeting)
      payload = PayloadBuilder.build_payload("meeting.created", meeting, "1")

      assert is_map(payload.data.meeting)
      assert payload.data.meeting.id == meeting.id
      assert payload.data.meeting.title == meeting.title
      assert payload.data.meeting.status == meeting.status
    end

    test "includes organizer data from the meeting" do
      meeting = build(:meeting, organizer_name: "Alice", organizer_email: "alice@example.com")
      payload = PayloadBuilder.build_payload("meeting.created", meeting, "1")

      organizer = payload.data.meeting.organizer
      assert organizer.name == "Alice"
      assert organizer.email == "alice@example.com"
    end

    test "includes attendee data from the meeting" do
      meeting =
        build(:meeting,
          attendee_name: "Bob",
          attendee_email: "bob@example.com",
          attendee_timezone: "Europe/London"
        )

      payload = PayloadBuilder.build_payload("meeting.created", meeting, "1")

      attendee = payload.data.meeting.attendee
      assert attendee.name == "Bob"
      assert attendee.email == "bob@example.com"
      assert attendee.timezone == "Europe/London"
    end

    test "includes booking URLs" do
      meeting =
        build(:meeting,
          view_url: "https://example.com/view",
          cancel_url: "https://example.com/cancel",
          reschedule_url: "https://example.com/reschedule"
        )

      payload = PayloadBuilder.build_payload("meeting.created", meeting, "1")

      urls = payload.data.meeting.urls
      assert urls.view == "https://example.com/view"
      assert urls.cancel == "https://example.com/cancel"
      assert urls.reschedule == "https://example.com/reschedule"
    end

    test "includes video data when video room is enabled" do
      meeting =
        build(:meeting,
          video_room_enabled: true,
          video_room_id: "room-123",
          organizer_video_url: "https://video.example.com/host",
          attendee_video_url: "https://video.example.com/guest"
        )

      payload = PayloadBuilder.build_payload("meeting.created", meeting, "1")

      video = payload.data.meeting.video
      assert video.enabled == true
      assert video.room_id == "room-123"
      assert video.organizer_url == "https://video.example.com/host"
      assert video.attendee_url == "https://video.example.com/guest"
    end

    test "omits room details when video is not enabled" do
      meeting = build(:meeting, video_room_enabled: false)
      payload = PayloadBuilder.build_payload("meeting.created", meeting, "1")

      assert payload.data.meeting.video == %{enabled: false}
    end

    test "includes cancellation data for cancelled meetings" do
      cancelled_at = ~U[2026-01-15 10:00:00Z]

      meeting =
        build(:meeting,
          status: "cancelled",
          cancelled_at: cancelled_at,
          cancellation_reason: "Schedule conflict"
        )

      payload = PayloadBuilder.build_payload("meeting.cancelled", meeting, "1")

      cancellation = payload.data.meeting.cancellation
      assert cancellation.reason == "Schedule conflict"
      assert is_binary(cancellation.cancelled_at)
      assert String.contains?(cancellation.cancelled_at, "2026-01-15")
    end

    test "does not include cancellation data for non-cancelled meetings" do
      meeting = build(:meeting, status: "confirmed")
      payload = PayloadBuilder.build_payload("meeting.created", meeting, "1")

      refute Map.has_key?(payload.data.meeting, :cancellation)
    end

    test "handles nil cancelled_at and nil reason for cancelled meetings without crashing" do
      meeting =
        build(:meeting,
          status: "cancelled",
          cancelled_at: nil,
          cancellation_reason: nil
        )

      payload = PayloadBuilder.build_payload("meeting.cancelled", meeting, "1")

      cancellation = payload.data.meeting.cancellation
      assert is_nil(cancellation.cancelled_at)
      assert is_nil(cancellation.reason)
    end

    test "handles nil video URLs when video room is enabled without crashing" do
      meeting =
        build(:meeting,
          video_room_enabled: true,
          video_room_id: "room-abc",
          organizer_video_url: nil,
          attendee_video_url: nil
        )

      payload = PayloadBuilder.build_payload("meeting.created", meeting, "1")

      video = payload.data.meeting.video
      assert video.enabled == true
      assert is_nil(video.organizer_url)
      assert is_nil(video.attendee_url)
    end
  end

  describe "build_test_payload/0" do
    test "returns a payload with the webhook.test event type" do
      payload = PayloadBuilder.build_test_payload()

      assert payload.event == "webhook.test"
    end

    test "includes a timestamp in ISO8601 format" do
      payload = PayloadBuilder.build_test_payload()

      assert is_binary(payload.timestamp)
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(payload.timestamp)
    end

    test "signals this is a test via the data field" do
      payload = PayloadBuilder.build_test_payload()

      assert payload.data.test == true
      assert is_binary(payload.data.message)
    end
  end
end
