defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.BookingConversationTest do
  @moduledoc """
  A booking's Talk conversation is found again rather than created twice, and
  brought up to date when it is. Exercised through the provider's room
  creation, which is how every caller reaches it; only the HTTP client is
  stubbed.
  """

  # The database holds the organiser whose language the conversation is
  # written in.
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :video

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.BookingConversation
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client
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
  @description "Booked through Tymeslot.\n\nReference: " <> @reference

  # As Talk lists the conversation an earlier attempt made for the booking:
  # public (type 3), owned by the integration's account (participant type 1).
  @made_earlier %{
    "token" => "made1st9",
    "type" => 3,
    "participantType" => 1,
    "name" => "Intro call",
    "lobbyState" => 1,
    "lobbyTimer" => 1_790_863_200,
    "description" => @description
  }

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
          %{"token" => "note2self", "type" => 6, "participantType" => 1, "description" => ""},
          %{@made_earlier | "token" => "other123", "description" => "Reference: 0123456789abcdef"}
        ])
      end)

      expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
        assert Jason.decode!(body) == %{
                 "roomType" => 3,
                 "roomName" => "Intro call",
                 "lobbyState" => 1,
                 "lobbyTimer" => DateTime.to_unix(@start),
                 "description" => @description
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

    test "writes the description in the organiser's language, keeping the reference untranslated" do
      organiser = insert(:user, locale: "de")

      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([])
      end)

      expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
        assert Jason.decode!(body)["description"] ==
                 "Über Tymeslot gebucht.\n\nReference: " <> @reference

        created(%{"token" => "abc123xy"})
      end)

      config = @config |> booking() |> Map.put(:user_id, organiser.id)
      assert {:ok, %RoomData{}} = NextcloudTalkProvider.create_meeting_room(config)
    end

    test "opens an all-day booking's lobby as its first day begins anywhere" do
      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([])
      end)

      expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
        # 14 hours before midnight UTC on 1 October.
        assert Jason.decode!(body)["lobbyTimer"] == DateTime.to_unix(~U[2026-09-30 10:00:00Z])
        created(%{"token" => "abc123xy"})
      end)

      config =
        put_in(booking(@config), [:event_details], %EventDetails{
          summary: "Offsite",
          start_time: ~D[2026-10-01],
          end_time: ~D[2026-10-02]
        })

      assert {:ok, %RoomData{}} = NextcloudTalkProvider.create_meeting_room(config)
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
  end

  describe "adopting the conversation an earlier attempt created" do
    test "adopts it, already up to date, without creating another" do
      # Only the lookup: any further request would fail the test as unexpected.
      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([%{"token" => "other123", "type" => 3, "description" => ""}, @made_earlier])
      end)

      assert {:ok, %RoomData{} = room} =
               NextcloudTalkProvider.create_meeting_room(booking(@config))

      assert room.room_id == "made1st9"
      assert room.meeting_url == "https://cloud.example.com/index.php/call/made1st9"
    end

    test "adopts one whose description was translated or edited around the reference line" do
      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([
          %{
            @made_earlier
            | "description" => "Über Tymeslot gebucht.\r\n\r\n  Reference: #{@reference}\nNotes"
          }
        ])
      end)

      assert {:ok, %RoomData{room_id: "made1st9"}} =
               NextcloudTalkProvider.create_meeting_room(booking(@config))
    end

    for {what, room} <- [
          {"one the account only takes part in", %{"participantType" => 3}},
          {"one that is not public", %{"type" => 2}},
          {"one whose reference only starts with the booking's",
           %{"description" => "Reference: 88348006c521d01e0"}},
          {"one naming the reference inside a sentence",
           %{"description" => "See Reference: 88348006c521d01e"}}
        ] do
      test "creates a new one rather than adopting #{what}" do
        room = Map.merge(@made_earlier, unquote(Macro.escape(room)))

        expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
          listed([room])
        end)

        expect(HTTPClientMock, :request, fn :post, @room_api, _body, _headers, _opts ->
          created(%{"token" => "abc123xy"})
        end)

        assert {:ok, %RoomData{room_id: "abc123xy"}} =
                 NextcloudTalkProvider.create_meeting_room(booking(@config))
      end
    end

    test "moves its lobby and renames it when the booking changed since the earlier attempt" do
      stale = %{@made_earlier | "name" => "Old title", "lobbyTimer" => 1_700_000_000}

      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([stale])
      end)

      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == @room_api <> "/made1st9/webinar/lobby"
        assert Jason.decode!(body) == %{"state" => 1, "timer" => DateTime.to_unix(@start)}
        {:ok, %Req.Response{status: 200, body: ocs(%{})}}
      end)

      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == @room_api <> "/made1st9"
        assert Jason.decode!(body) == %{"roomName" => "Intro call"}
        {:ok, %Req.Response{status: 200, body: ocs(%{})}}
      end)

      assert {:ok, %RoomData{room_id: "made1st9"}} =
               NextcloudTalkProvider.create_meeting_room(booking(@config))
    end

    test "keeps it when Talk refuses the update, which no retry would change" do
      stale = %{@made_earlier | "name" => "Old title", "lobbyTimer" => 1_700_000_000}

      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([stale])
      end)

      expect(HTTPClientMock, :request, 2, fn :put, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: ocs(%{"error" => "permissions"})}}
      end)

      assert {:ok, %RoomData{room_id: "made1st9"}} =
               NextcloudTalkProvider.create_meeting_room(booking(@config))
    end

    test "fails, for the room job to retry, when the update never completes" do
      stale = %{@made_earlier | "lobbyTimer" => 1_700_000_000}
      failure = %Req.TransportError{reason: :timeout}

      expect(HTTPClientMock, :request, fn :get, @room_list, _body, _headers, _opts ->
        listed([stale])
      end)

      expect(HTTPClientMock, :request, fn :put, _url, _body, _headers, _opts ->
        {:error, failure}
      end)

      assert {:error, ^failure} = NextcloudTalkProvider.create_meeting_room(booking(@config))
    end
  end

  test "the network budget covers the slower of creating and bringing an adopted conversation up to date" do
    lookup = Client.request_budget_ms(:get)

    assert BookingConversation.budget_ms() >= lookup + Client.request_budget_ms(:post)
    assert BookingConversation.budget_ms() >= lookup + 2 * Client.request_budget_ms(:put)
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
