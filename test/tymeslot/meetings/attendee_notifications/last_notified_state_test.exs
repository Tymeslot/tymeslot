defmodule Tymeslot.Meetings.AttendeeNotifications.LastNotifiedStateTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState

  describe "serialise/2" do
    test "captures the notifiable fields and attendee emails" do
      event = %{
        title: "Design review",
        starts_at: ~U[2026-04-15 14:00:00Z],
        ends_at: ~U[2026-04-15 15:00:00Z],
        location: "Studio A",
        description: "Go over wireframes",
        video_link: "https://meet.example.com/abc"
      }

      attendees = [%{email: "Alice@Example.com "}, %{email: "bob@example.com"}]
      state = LastNotifiedState.serialise(event, attendees)

      assert state["title"] == "Design review"
      assert state["starts_at"] == "2026-04-15T14:00:00Z"
      assert state["attendees"] == ["alice@example.com", "bob@example.com"]
    end

    test "coerces nils to empty strings for text fields" do
      state = LastNotifiedState.serialise(%{title: nil, description: nil}, [])
      assert state["title"] == ""
      assert state["description"] == ""
    end
  end

  describe "to_event/1" do
    test "round-trips serialised state into a pseudo event map" do
      attendees = [%{email: "a@x.com"}]

      event = %{
        title: "t",
        starts_at: ~U[2026-01-01 00:00:00Z],
        ends_at: ~U[2026-01-01 01:00:00Z],
        location: "",
        description: "",
        video_link: nil
      }

      state = LastNotifiedState.serialise(event, attendees)

      pseudo = LastNotifiedState.to_event(state)
      assert pseudo.title == "t"
      assert pseudo.attendees == [%{email: "a@x.com"}]
    end
  end
end
