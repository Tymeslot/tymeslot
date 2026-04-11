defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilderTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder

  @base_meeting %{
    uid: "abc-123",
    title: "Team Sync",
    description: "Quarterly review",
    start_time: ~U[2026-05-01 10:00:00Z],
    end_time: ~U[2026-05-01 11:00:00Z],
    attendee_timezone: "Europe/London",
    meeting_url: nil,
    location: nil,
    attendee_name: "Alice",
    attendee_email: "alice@example.com",
    attendee_message: nil
  }

  describe "build_event_data/1" do
    test "maps all standard fields from the meeting" do
      meeting = @base_meeting

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.uid == "abc-123"
      assert result.summary == "Team Sync"
      assert result.start_time == ~U[2026-05-01 10:00:00Z]
      assert result.end_time == ~U[2026-05-01 11:00:00Z]
      assert result.timezone == "Europe/London"
      assert result.attendee_name == "Alice"
      assert result.attendee_email == "alice@example.com"
    end

    test "prefers meeting_url over location for the location field" do
      meeting = %{
        @base_meeting
        | meeting_url: "https://meet.example.com/room",
          location: "Office"
      }

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.location == "https://meet.example.com/room"
    end

    test "falls back to location when meeting_url is nil" do
      meeting = %{@base_meeting | meeting_url: nil, location: "Conference Room B"}

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.location == "Conference Room B"
    end

    test "uses \"To be determined\" when both meeting_url and location are nil" do
      meeting = %{@base_meeting | meeting_url: nil, location: nil}

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.location == "To be determined"
    end

    test "description is assembled from build_event_description" do
      meeting = %{@base_meeting | attendee_message: "Looking forward to it!"}

      result = CalendarEventBuilder.build_event_data(meeting)

      assert result.description =~ "Quarterly review"
      assert result.description =~ "Looking forward to it!"
    end
  end

  describe "build_event_description/1" do
    test "returns only the base description when no attendee message or meeting URL" do
      meeting = %{@base_meeting | attendee_message: nil, meeting_url: nil}

      assert CalendarEventBuilder.build_event_description(meeting) == "Quarterly review"
    end

    test "appends attendee message with section header when present" do
      meeting = %{@base_meeting | attendee_message: "Please bring slides.", meeting_url: nil}

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == "Quarterly review\n\nMessage from attendee:\nPlease bring slides."
    end

    test "appends video meeting URL with section header when present" do
      meeting = %{
        @base_meeting
        | attendee_message: nil,
          meeting_url: "https://meet.example.com/room"
      }

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == "Quarterly review\n\nVideo meeting: https://meet.example.com/room"
    end

    test "appends both attendee message and video URL when both are present" do
      meeting = %{
        @base_meeting
        | attendee_message: "See you there!",
          meeting_url: "https://meet.example.com/room"
      }

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result ==
               "Quarterly review\n\nMessage from attendee:\nSee you there!\n\nVideo meeting: https://meet.example.com/room"
    end

    test "handles nil base description without crashing" do
      meeting = %{@base_meeting | description: nil, attendee_message: nil, meeting_url: nil}

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == ""
    end

    test "handles nil base description with attendee message" do
      meeting = %{@base_meeting | description: nil, attendee_message: "Hi!", meeting_url: nil}

      result = CalendarEventBuilder.build_event_description(meeting)

      assert result == "\n\nMessage from attendee:\nHi!"
    end
  end
end
