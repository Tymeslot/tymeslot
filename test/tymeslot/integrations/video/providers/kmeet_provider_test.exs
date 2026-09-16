defmodule Tymeslot.Integrations.Video.Providers.KmeetProviderTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Video.Providers.KmeetProvider
  alias Tymeslot.Integrations.Video.RoomData

  setup :verify_on_exit!

  describe "identity" do
    test "declares its provider type, name and bucket" do
      assert KmeetProvider.provider_type() == :kmeet
      assert KmeetProvider.display_name() == "kMeet"
      assert KmeetProvider.connection_test_bucket() == :kmeet
    end
  end

  describe "create_meeting_room/1" do
    test "builds a room on the kMeet host from the meeting id" do
      assert {:ok, %RoomData{} = room} = KmeetProvider.create_meeting_room(%{meeting_id: "m-1"})
      assert room.meeting_url =~ ~r/\Ahttps:\/\/kmeet\.infomaniak\.com\/[0-9a-f]{16}\z/
      assert room.meeting_url == "https://kmeet.infomaniak.com/" <> room.room_id
    end

    test "is deterministic for the same meeting id" do
      {:ok, first} = KmeetProvider.create_meeting_room(%{meeting_id: "m-1"})
      {:ok, second} = KmeetProvider.create_meeting_room(%{meeting_id: "m-1"})
      assert first.meeting_url == second.meeting_url
    end

    test "gives different meetings different rooms" do
      {:ok, first} = KmeetProvider.create_meeting_room(%{meeting_id: "m-1"})
      {:ok, second} = KmeetProvider.create_meeting_room(%{meeting_id: "m-2"})
      refute first.meeting_url == second.meeting_url
    end

    test "refuses a missing meeting id rather than inventing a shared room" do
      assert KmeetProvider.create_meeting_room(%{}) ==
               {:error, "A meeting ID is required to create a video room"}
    end
  end

  describe "validate_config/1" do
    test "accepts an empty config: there is nothing for the user to get wrong" do
      assert :ok = KmeetProvider.validate_config(%{})
    end
  end

  describe "create_join_url/5" do
    test "hands every participant the same room URL" do
      {:ok, room} = KmeetProvider.create_meeting_room(%{meeting_id: "m-1"})

      assert {:ok, url} =
               KmeetProvider.create_join_url(room, "Ada", "ada@example.com", "organizer", nil)

      assert url == room.meeting_url
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts a kMeet room URL and rejects a non-HTTP one" do
      assert KmeetProvider.valid_meeting_url?("https://kmeet.infomaniak.com/abc")
      refute KmeetProvider.valid_meeting_url?("ftp://kmeet.infomaniak.com/abc")
    end
  end

  describe "extract_room_id/1" do
    test "recovers the room id create_meeting_room/1 embedded in the URL" do
      {:ok, room} = KmeetProvider.create_meeting_room(%{meeting_id: "m-1"})

      assert KmeetProvider.extract_room_id(room.meeting_url) == room.room_id
    end
  end

  describe "perform_connection_test/1" do
    test "probes the fixed kMeet host and reports its status" do
      expect(Tymeslot.HTTPClientMock, :head, fn "https://kmeet.infomaniak.com", _headers, _opts ->
        {:ok, %Req.Response{status: 200, headers: %{}}}
      end)

      assert KmeetProvider.perform_connection_test(%{}) ==
               {:ok, "URL responded with HTTP 200"}
    end
  end
end
