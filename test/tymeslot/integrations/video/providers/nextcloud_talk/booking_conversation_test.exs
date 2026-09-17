defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.BookingConversationTest do
  @moduledoc """
  A booking's Talk conversation is found again rather than created twice.
  Exercised through the provider's room creation, which is how every caller
  reaches it; only the HTTP client is stubbed.
  """

  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :video

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.BookingConversation
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.RoomData

  setup :verify_on_exit!

  @room_api "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room"
  @room_list @room_api <> "?noStatusUpdate=1&includeLastMessage=0"
  @start ~U[2026-10-01 14:00:00Z]
  @throttled ~s({"ocs":{"meta":{"status":"failure","statuscode":429,"message":"Reached maximum delay"},"data":[]}})

  # A booking's meeting id, and the first 16 hex characters of its SHA-256,
  # which is the reference its conversation carries.
  @meeting_id "0b7f2c9e-5d41-4c1a-9e3b-7a6f1d2c8e90"
  @reference "88348006c521d01e"

  @config %{
    base_url: "https://cloud.example.com",
    client_id: "organiser",
    client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy",
    needs_reauth: false
  }

  describe "creating a booking's conversation" do
    test "looks through the organiser's conversations first, then creates one carrying the booking's reference" do
      expect(HTTPClientMock, :request, fn :get, @room_list, "", _headers, _opts ->
        listed([
          %{"token" => "note2self", "type" => 6, "description" => "Private notes"},
          %{
            "token" => "other123",
            "type" => 3,
            "description" => "Booked through Tymeslot. Reference: 0123456789abcdef"
          }
        ])
      end)

      expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
        assert Jason.decode!(body) == %{
                 "roomType" => 3,
                 "roomName" => "Intro call",
                 "lobbyState" => 1,
                 "lobbyTimer" => DateTime.to_unix(@start),
                 "description" => "Booked through Tymeslot. Reference: " <> @reference
               }

        created(%{"token" => "abc123xy"})
      end)

      assert {:ok, %RoomData{room_id: "abc123xy"}} =
               NextcloudTalkProvider.create_meeting_room(booking(@config))
    end

    test "never shows the meeting id itself in the conversation" do
      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([])
      end)

      expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
        refute body =~ @meeting_id
        created(%{"token" => "abc123xy"})
      end)

      assert {:ok, %RoomData{}} = NextcloudTalkProvider.create_meeting_room(booking(@config))
    end

    test "adopts the conversation an earlier attempt created instead of creating another" do
      # Only the lookup: a creation request would fail the test as unexpected.
      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([
          %{"token" => "other123", "type" => 3, "description" => ""},
          %{
            "token" => "made1st9",
            "type" => 3,
            "name" => "Intro call",
            "description" => "Gebucht über Tymeslot. Referenz: " <> @reference
          }
        ])
      end)

      assert {:ok, %RoomData{} = room} =
               NextcloudTalkProvider.create_meeting_room(booking(@config))

      assert room.room_id == "made1st9"
      assert room.meeting_url == "https://cloud.example.com/index.php/call/made1st9"
    end

    test "creates nothing while the lookup is throttled" do
      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: @throttled}}
      end)

      assert {:error, :rate_limited} =
               NextcloudTalkProvider.create_meeting_room(booking(@config))
    end

    test "creates nothing when the lookup never completes" do
      failure = %Req.TransportError{reason: :timeout}

      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        {:error, failure}
      end)

      assert {:error, ^failure} = NextcloudTalkProvider.create_meeting_room(booking(@config))
    end

    test "a lookup answer that is not a list of conversations is not a room" do
      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ocs(%{"token" => "abc123xy"})}}
      end)

      assert {:error, :invalid_response} =
               NextcloudTalkProvider.create_meeting_room(booking(@config))
    end

    test "declares a network budget covering the lookup and the creation" do
      assert BookingConversation.budget_ms() == 40_000
      assert NextcloudTalkProvider.room_creation_budget_ms() == BookingConversation.budget_ms()
    end
  end

  defp booking(config) do
    Map.merge(config, %{
      meeting_id: @meeting_id,
      event_details: %EventDetails{
        summary: "Intro call",
        start_time: @start,
        end_time: DateTime.add(@start, 1800, :second)
      }
    })
  end

  defp listed(rooms), do: {:ok, %Req.Response{status: 200, body: ocs(rooms)}}

  defp created(data), do: {:ok, %Req.Response{status: 201, body: ocs(data)}}

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
end
