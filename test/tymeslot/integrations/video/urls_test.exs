defmodule Tymeslot.Integrations.Video.UrlsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Urls

  describe "extract_room_id/1" do
    test "extracts room_id from map" do
      assert Urls.extract_room_id(%{room_data: %{room_id: "room123"}}) == "room123"
      assert Urls.extract_room_id(%{room_data: %{}}) == "unknown"
    end

    test "returns \"unknown\" when room_id is not a binary" do
      assert Urls.extract_room_id(%{room_data: %{room_id: nil}}) == "unknown"
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

  describe "valid_meeting_url?/1" do
    test "validates supported video URLs" do
      assert Urls.valid_meeting_url?("https://meet.google.com/abc-defg-hij")
      assert Urls.valid_meeting_url?("https://teams.microsoft.com/l/meetup-join/test")
      refute Urls.valid_meeting_url?("https://example.com")
      refute Urls.valid_meeting_url?(nil)
    end
  end
end
