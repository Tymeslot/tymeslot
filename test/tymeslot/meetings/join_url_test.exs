defmodule Tymeslot.Meetings.JoinUrlTest do
  use ExUnit.Case, async: true

  @moduletag :meetings
  @moduletag :video

  alias Tymeslot.Meetings.JoinUrl
  alias Tymeslot.Meetings.MeetingSchema

  describe "organizer_join_url/1" do
    test "prefers the host's own room link" do
      meeting = %MeetingSchema{
        organizer_video_url: "https://video.example.com/host/abc",
        meeting_url: "https://video.example.com/join/abc"
      }

      assert JoinUrl.organizer_join_url(meeting) == "https://video.example.com/host/abc"
    end

    test "falls back to the shared meeting link without a host link" do
      meeting = %MeetingSchema{
        organizer_video_url: nil,
        meeting_url: "https://video.example.com/join/abc"
      }

      assert JoinUrl.organizer_join_url(meeting) == "https://video.example.com/join/abc"
    end

    test "treats a blank host link as missing" do
      meeting = %MeetingSchema{
        organizer_video_url: "   ",
        meeting_url: "https://video.example.com/join/abc"
      }

      assert JoinUrl.organizer_join_url(meeting) == "https://video.example.com/join/abc"
    end

    test "trims the link it returns" do
      meeting = %MeetingSchema{
        organizer_video_url: "  https://video.example.com/host/abc\n",
        meeting_url: nil
      }

      assert JoinUrl.organizer_join_url(meeting) == "https://video.example.com/host/abc"
    end

    test "is nil for a meeting without video" do
      assert JoinUrl.organizer_join_url(%MeetingSchema{organizer_video_url: nil, meeting_url: ""}) ==
               nil
    end
  end
end
