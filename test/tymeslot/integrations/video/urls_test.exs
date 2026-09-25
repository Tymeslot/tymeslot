defmodule Tymeslot.Integrations.Video.UrlsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Urls

  describe "extract_room_id/1" do
    test "extracts room_id from map" do
      assert Urls.extract_room_id(%{room_data: %{room_id: "room123"}}) == "room123"
    end

    test "returns nil for a context whose room_data carries no room id" do
      # A placeholder such as "unknown" would read as a real room id to callers
      # and let an unusable room be attached to a booking.
      assert Urls.extract_room_id(%{room_data: %{}}) == nil
      assert Urls.extract_room_id(%{room_data: %{meeting_url: nil}}) == nil
    end

    test "extracts room_id from binary URL" do
      # Google Meet example
      assert Urls.extract_room_id("https://meet.google.com/abc-defg-hij") == "abc-defg-hij"
      # Teams example
      assert Urls.extract_room_id("https://teams.microsoft.com/l/meetup-join/19%3ameeting_test") ==
               "19%3ameeting_test"
    end

    test "returns nil for invalid input" do
      assert Urls.extract_room_id(nil) == nil
      assert Urls.extract_room_id(123) == nil
    end
  end

  describe "extract_room_id/2" do
    test "parses by the named provider's rules rather than guessing from the URL" do
      # MiroTalk's "/join/" pattern claims this link and is listed first, so
      # the URL-only function answers with its last path segment. The custom
      # provider, which actually issued it, derives the id from the whole URL.
      url = "https://whereby.com/join/team-standup"

      assert Urls.extract_room_id(url) == "team-standup"
      assert Urls.extract_room_id(url, :custom) == "176c39fdfe37cdea"
    end

    test "returns nil for a non-binary URL" do
      assert Urls.extract_room_id(nil, :custom) == nil
      assert Urls.extract_room_id(%{room_data: %{room_id: "room123"}}, :custom) == nil
    end
  end

  describe "valid_meeting_url?/1" do
    test "validates supported video URLs" do
      assert Urls.valid_meeting_url?("https://meet.google.com/abc-defg-hij")
      assert Urls.valid_meeting_url?("https://teams.microsoft.com/l/meetup-join/test")
      refute Urls.valid_meeting_url?("https://example.com")
      refute Urls.valid_meeting_url?(nil)
    end
  end
end
