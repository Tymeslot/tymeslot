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

    test "returns nil for anything but a meeting context" do
      assert Urls.extract_room_id("https://meet.google.com/abc-defg-hij") == nil
      assert Urls.extract_room_id(nil) == nil
      assert Urls.extract_room_id(123) == nil
    end
  end

  describe "extract_room_id/2" do
    test "parses by the named provider's rules" do
      # The custom provider derives the id from the whole URL, so a link whose
      # path ends in a plausible room name still yields its digest.
      url = "https://whereby.com/join/team-standup"

      assert Urls.extract_room_id(url, :custom) == "176c39fdfe37cdea"
    end

    test "returns nil for a non-binary URL" do
      assert Urls.extract_room_id(nil, :custom) == nil
      assert Urls.extract_room_id(%{room_data: %{room_id: "room123"}}, :custom) == nil
    end
  end
end
