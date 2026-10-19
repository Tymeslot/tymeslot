defmodule Tymeslot.Emails.Shared.JoinUrlTest do
  use ExUnit.Case, async: true
  @moduletag :emails
  @moduletag :unit

  alias Tymeslot.Emails.Shared.JoinUrl

  @details %{
    meeting_url: "https://meet.example.com/room",
    organizer_video_url: "https://meet.example.com/room?role=host",
    attendee_video_url: "https://meet.example.com/room?role=participant",
    guest_video_url: "https://meet.example.com/room?role=guest"
  }

  describe "for/2" do
    test "gives each role its own link" do
      assert JoinUrl.for(:organizer, @details) == @details.organizer_video_url
      assert JoinUrl.for(:attendee, @details) == @details.attendee_video_url
      assert JoinUrl.for(:guest, @details) == @details.guest_video_url
    end

    test "falls back to the room URL for every role" do
      details = %{meeting_url: "https://meet.example.com/room"}

      assert JoinUrl.for(:organizer, details) == "https://meet.example.com/room"
      assert JoinUrl.for(:attendee, details) == "https://meet.example.com/room"
      assert JoinUrl.for(:guest, details) == "https://meet.example.com/room"
    end

    test "is nil when there is no room at all" do
      assert JoinUrl.for(:organizer, %{}) == nil
      assert JoinUrl.for(:attendee, %{}) == nil
      assert JoinUrl.for(:guest, %{}) == nil
    end

    test "treats an empty own link as absent, so the room URL applies" do
      details = %{meeting_url: "https://meet.example.com/room"}

      for {role, key} <- [
            organizer: :organizer_video_url,
            attendee: :attendee_video_url,
            guest: :guest_video_url
          ] do
        assert JoinUrl.for(role, Map.put(details, key, "")) == "https://meet.example.com/room"
      end
    end
  end
end
