defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkProviderTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.RoomData

  setup :verify_on_exit!

  @server "https://cloud.example.com"
  @room_api "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room"
  @start ~U[2026-10-01 14:00:00Z]
  @moved_start ~U[2026-10-08 09:30:00Z]

  # Answers as Nextcloud 34 with Talk 24 sends them. A lobby move or a rename
  # answers with the whole conversation; these are the fields that matter.
  @room %{"token" => "abc123xy", "type" => 3, "name" => "Moved call", "lobbyState" => 1}
  @unauthorised ~s({"ocs":{"meta":{"status":"failure","statuscode":997,"message":"Unauthorised"},"data":[]}})
  @throttled ~s({"ocs":{"meta":{"status":"failure","statuscode":429,"message":"Reached maximum delay"},"data":[]}})

  @config %{
    base_url: @server,
    client_id: "organiser",
    client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy",
    needs_reauth: false
  }

  describe "identity" do
    test "declares its provider type, name and bucket" do
      assert NextcloudTalkProvider.provider_type() == :nextcloud_talk
      assert NextcloudTalkProvider.display_name() == "Nextcloud Talk"
      assert NextcloudTalkProvider.connection_test_bucket() == :nextcloud_talk
    end
  end

  describe "validate_config/1" do
    test "accepts a server, login name and app password" do
      assert :ok = NextcloudTalkProvider.validate_config(@config)
    end

    test "requires the server address" do
      assert {:error, message} = NextcloudTalkProvider.validate_config(%{@config | base_url: " "})
      assert message =~ "required"
    end

    test "requires the login name" do
      assert {:error, message} = NextcloudTalkProvider.validate_config(%{@config | client_id: ""})
      assert message =~ "Login name"
    end

    test "requires the app password" do
      assert {:error, message} =
               NextcloudTalkProvider.validate_config(%{@config | client_secret: nil})

      assert message =~ "App password"
    end

    test "refuses a server address with a query string" do
      assert {:error, message} =
               NextcloudTalkProvider.validate_config(%{@config | base_url: @server <> "/?x=1"})

      assert message =~ "query string"
    end

    test "refuses a server address that is not an http or https URL" do
      assert {:error, _message} =
               NextcloudTalkProvider.validate_config(%{@config | base_url: "cloud.example.com"})
    end

    test "refuses a server address with a fragment" do
      assert {:error, message} =
               NextcloudTalkProvider.validate_config(%{@config | base_url: @server <> "/#talk"})

      assert message =~ "fragment"
    end

    test "refuses plain http on a public server, which would send the app password unencrypted" do
      assert {:error, message} =
               NextcloudTalkProvider.validate_config(%{
                 @config
                 | base_url: "http://cloud.example.com"
               })

      assert message =~ "https://"
    end

    test "refuses a login name and password embedded in the server address" do
      assert {:error, message} =
               NextcloudTalkProvider.validate_config(%{
                 @config
                 | base_url: "https://organiser:secret@cloud.example.com"
               })

      assert message =~ "login name or password"
    end

    test "refuses whitespace inside the server address" do
      assert {:error, message} =
               NextcloudTalkProvider.validate_config(%{
                 @config
                 | base_url: "https://cloud.example.com/next cloud"
               })

      assert message =~ "spaces"
    end

    test "refuses a server and login too long to store together" do
      long_server = "https://cloud.example.com/" <> String.duplicate("a", 230)

      assert {:error, message} =
               NextcloudTalkProvider.validate_config(%{@config | base_url: long_server})

      assert message =~ "too long"
    end
  end

  describe "create_meeting_room/1" do
    test "creates a public conversation named after the booking, its lobby lifting at the start" do
      expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
        assert Jason.decode!(body) == %{
                 "roomType" => 3,
                 "roomName" => "Intro call",
                 "permissions" => 244,
                 "lobbyState" => 1,
                 "lobbyTimer" => DateTime.to_unix(@start)
               }

        created(%{"token" => "abc123xy"})
      end)

      assert {:ok, %RoomData{} = room} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))

      assert room.room_id == "abc123xy"
      assert room.meeting_url == "https://cloud.example.com/index.php/call/abc123xy"
    end

    test "keeps a sub-path on the server address, trailing slash or not" do
      expect(HTTPClientMock, :request, fn :post, url, _body, _headers, _opts ->
        assert url == "https://cloud.example.com/nextcloud/ocs/v2.php/apps/spreed/api/v4/room"
        created(%{"token" => "abc123xy"})
      end)

      config = with_event(%{@config | base_url: "https://cloud.example.com/nextcloud/"})

      assert {:ok, room} = NextcloudTalkProvider.create_meeting_room(config)
      assert room.meeting_url == "https://cloud.example.com/nextcloud/index.php/call/abc123xy"
    end

    test "keeps the credentials out of the room's provider data" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        created(%{"token" => "abc123xy"})
      end)

      assert {:ok, room} = NextcloudTalkProvider.create_meeting_room(with_event(@config))

      refute inspect(room.provider_data) =~ @config.client_secret

      refute inspect(NextcloudTalkProvider.generate_meeting_metadata(room)) =~
               @config.client_secret

      refute inspect(room) =~ @config.client_secret
    end

    test "opens the conversation at once when the booking has no start time" do
      expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
        refute Map.has_key?(Jason.decode!(body), "lobbyState")
        created(%{"token" => "abc123xy"})
      end)

      config = Map.put(@config, :event_details, %EventDetails{summary: "Intro call"})
      assert {:ok, %RoomData{}} = NextcloudTalkProvider.create_meeting_room(config)
    end

    test "a server throttling Tymeslot's address is a rate limit to back off from" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: @throttled}}
      end)

      assert {:error, :rate_limited} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end

    test "a success without a token is not a room" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts -> created(%{}) end)

      assert {:error, :invalid_response} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end

    test "a success with null data is not a room" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts -> created(nil) end)

      assert {:error, :invalid_response} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end

    test "a token Talk would not route is not a room" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        created(%{"token" => "../ABC"})
      end)

      assert {:error, :invalid_response} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end

    test "a transport failure passes through for the breaker to witness" do
      failure = %Req.TransportError{reason: :timeout}

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:error, failure}
      end)

      assert {:error, ^failure} = NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end

    test "an integration flagged for reconnection never calls the server" do
      config = with_event(%{@config | needs_reauth: true})
      assert {:error, :unauthorized} = NextcloudTalkProvider.create_meeting_room(config)
    end
  end

  describe "create_join_url/5" do
    test "hands every participant the conversation's public link" do
      room = %RoomData{
        room_id: "abc123xy",
        meeting_url: "https://cloud.example.com/index.php/call/abc123xy",
        provider_data: %{}
      }

      assert {:ok, organiser} =
               NextcloudTalkProvider.create_join_url(
                 room,
                 "Olivia",
                 "o@example.com",
                 "organizer",
                 @start
               )

      assert {:ok, guest} =
               NextcloudTalkProvider.create_join_url(
                 room,
                 "Grace",
                 "g@example.com",
                 "participant",
                 @start
               )

      assert organiser == room.meeting_url
      assert guest == room.meeting_url
    end
  end

  describe "extract_room_id/1 and valid_meeting_url?/1" do
    test "read the token from both link forms" do
      assert NextcloudTalkProvider.extract_room_id(@server <> "/index.php/call/abc123xy") ==
               "abc123xy"

      assert NextcloudTalkProvider.extract_room_id(@server <> "/call/abc123xy") == "abc123xy"
      assert NextcloudTalkProvider.valid_meeting_url?(@server <> "/call/abc123xy")
    end

    test "refuse a link that is not a Talk call" do
      assert NextcloudTalkProvider.extract_room_id(@server <> "/apps/files") == nil
      refute NextcloudTalkProvider.valid_meeting_url?(@server <> "/apps/files")
      refute NextcloudTalkProvider.valid_meeting_url?("ftp://cloud.example.com/call/abc123xy")
    end

    test "refuse a token outside Talk's token format" do
      assert NextcloudTalkProvider.extract_room_id(@server <> "/call/ABC123XY") == nil
      assert NextcloudTalkProvider.extract_room_id(@server <> "/call/abc") == nil
      refute NextcloudTalkProvider.valid_meeting_url?(@server <> "/call/abc-123")
    end
  end

  describe "perform_connection_test/1" do
    test "succeeds against a Talk that can create configured conversations" do
      expect_signed_in()

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        capabilities(%{"version" => "25.0.0", "features" => ["conversation-creation-all"]})
      end)

      assert {:ok, message} = NextcloudTalkProvider.perform_connection_test(@config)
      assert message =~ "25.0.0"
    end

    test "refuses a Talk too old to set the lobby when creating a conversation" do
      expect_signed_in()

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        capabilities(%{"version" => "20.0.0", "features" => ["chat-v2"]})
      end)

      assert {:error, {:unreachable, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "21.1"
    end

    test "refuses a server where Talk is not available to the account" do
      expect_signed_in()

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ocs(%{"capabilities" => %{"core" => %{}}})}}
      end)

      assert {:error, {:unreachable, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "Talk app"
    end

    test "reports a refused app password against the password" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: @unauthorised}}
      end)

      assert {:error, {:unauthorized, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "app password"
    end

    test "asks the user to wait when the server is throttling Tymeslot's address" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: @throttled}}
      end)

      assert {:error, {:throttled, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "Wait a few minutes before trying again"
    end

    test "asks for the address the browser ends up on after a redirect" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{status: 301, headers: %{"location" => ["https://cloud.example.com/"]}}}
      end)

      assert {:error, {:unreachable, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "redirected"
    end

    test "an integration flagged for reconnection is not tested against the server" do
      assert {:error, {:unauthorized, _message}} =
               NextcloudTalkProvider.perform_connection_test(%{@config | needs_reauth: true})
    end
  end

  describe "update_meeting_room/2" do
    test "moves the lobby to the new start, then renames the conversation" do
      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy/webinar/lobby"
        assert Jason.decode!(body) == %{"state" => 1, "timer" => DateTime.to_unix(@moved_start)}
        {:ok, %Req.Response{status: 200, body: ocs(@room)}}
      end)

      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy"
        assert Jason.decode!(body) == %{"roomName" => "Moved call"}
        {:ok, %Req.Response{status: 200, body: ocs(@room)}}
      end)

      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", rescheduled(@config))
    end

    test "only moves the lobby when the booking has no title to rename to" do
      expect(HTTPClientMock, :request, fn :put, url, _body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy/webinar/lobby"
        {:ok, %Req.Response{status: 200, body: ocs(@room)}}
      end)

      config = Map.put(@config, :meeting_start_time, @moved_start)

      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", config)
    end

    test "skips the rename when the new title is blank" do
      expect(HTTPClientMock, :request, fn :put, url, _body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy/webinar/lobby"
        {:ok, %Req.Response{status: 200, body: ocs(@room)}}
      end)

      config = Map.merge(@config, %{meeting_start_time: @moved_start, meeting_topic: "  \n "})

      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", config)
    end

    test "renames to the trimmed title" do
      expect(HTTPClientMock, :request, fn :put, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ocs(@room)}}
      end)

      expect(HTTPClientMock, :request, fn :put, _url, body, _headers, _opts ->
        assert Jason.decode!(body) == %{"roomName" => "Moved call"}
        {:ok, %Req.Response{status: 200, body: ocs(@room)}}
      end)

      config =
        Map.merge(@config, %{meeting_start_time: @moved_start, meeting_topic: " Moved call "})

      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", config)
    end

    test "reports a conversation deleted on the server as not found" do
      expect(HTTPClientMock, :request, fn :put, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: failure(404, [])}}
      end)

      assert {:error, :meeting_not_found} =
               NextcloudTalkProvider.update_meeting_room("abc123xy", rescheduled(@config))
    end

    test "keeps the moved lobby when the server refuses the rename" do
      expect(HTTPClientMock, :request, fn :put, url, _body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy/webinar/lobby"
        {:ok, %Req.Response{status: 200, body: ocs(@room)}}
      end)

      expect(HTTPClientMock, :request, fn :put, url, _body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy"
        {:ok, %Req.Response{status: 400, body: failure(400, %{"error" => "value"})}}
      end)

      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", rescheduled(@config))
    end

    test "reports a lobby the server refuses to move as a configuration error" do
      expect(HTTPClientMock, :request, fn :put, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: failure(403, nil)}}
      end)

      assert {:error, {:configuration_error, {:rejected, 403}}} =
               NextcloudTalkProvider.update_meeting_room("abc123xy", rescheduled(@config))
    end

    test "fails, for the sync job to retry, when the lobby cannot be moved" do
      expect(HTTPClientMock, :request, fn :put, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 503, body: ""}}
      end)

      assert {:error, {:http_error, 503}} =
               NextcloudTalkProvider.update_meeting_room("abc123xy", rescheduled(@config))
    end

    test "passes a throttled server on for the sync job to snooze" do
      expect(HTTPClientMock, :request, fn :put, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: @throttled}}
      end)

      assert {:error, :rate_limited} =
               NextcloudTalkProvider.update_meeting_room("abc123xy", rescheduled(@config))
    end

    test "an integration flagged for reconnection never calls the server" do
      assert {:error, :unauthorized} =
               NextcloudTalkProvider.update_meeting_room(
                 "abc123xy",
                 rescheduled(%{@config | needs_reauth: true})
               )
    end
  end

  describe "delete_meeting_room/2" do
    test "deletes the conversation" do
      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy"
        {:ok, %Req.Response{status: 200, body: ocs(nil)}}
      end)

      assert :ok = NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "treats a conversation already gone as deleted" do
      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: failure(404, [])}}
      end)

      assert :ok = NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "treats a conversation its owner marked to be preserved as done" do
      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: failure(403, %{"error" => "preserved"})}}
      end)

      assert :ok = NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "treats a token Talk would not route as no conversation, without a request" do
      assert :ok = NextcloudTalkProvider.delete_meeting_room("../abc", @config)
    end

    test "reports a deletion the server refuses as a configuration error" do
      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: failure(400, nil)}}
      end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: failure(403, nil)}}
      end)

      assert {:error, {:configuration_error, {:rejected, 400}}} =
               NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)

      assert {:error, {:configuration_error, {:rejected, 403}}} =
               NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "reports a redirecting server as a configuration error" do
      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{status: 302, headers: %{"location" => ["https://cloud.example.com/login"]}}}
      end)

      assert {:error, {:configuration_error, :redirected}} =
               NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "fails, for the sync job to retry, when the server is unwell" do
      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 502, body: ""}}
      end)

      assert {:error, {:http_error, 502}} =
               NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "passes a throttled server on for the sync job to snooze" do
      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: @throttled}}
      end)

      assert {:error, :rate_limited} =
               NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "an integration flagged for reconnection never calls the server" do
      assert {:error, :unauthorized} =
               NextcloudTalkProvider.delete_meeting_room("abc123xy", %{
                 @config
                 | needs_reauth: true
               })
    end
  end

  defp with_event(config) do
    Map.put(config, :event_details, %EventDetails{
      summary: "Intro call",
      start_time: @start,
      end_time: DateTime.add(@start, 1800, :second)
    })
  end

  defp rescheduled(config),
    do: Map.merge(config, %{meeting_start_time: @moved_start, meeting_topic: "Moved call"})

  defp created(data), do: {:ok, %Req.Response{status: 201, body: ocs(data)}}

  # Nextcloud answers the capabilities endpoint anonymously too, so every
  # connection test asks who is signed in first.
  defp expect_signed_in do
    expect(HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
      assert String.ends_with?(url, "/ocs/v2.php/cloud/user")
      {:ok, %Req.Response{status: 200, body: ocs(%{"id" => "organiser"})}}
    end)
  end

  defp capabilities(spreed),
    do: {:ok, %Req.Response{status: 200, body: ocs(%{"capabilities" => %{"spreed" => spreed}})}}

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})

  defp failure(status, data) do
    Jason.encode!(%{
      "ocs" => %{
        "meta" => %{"status" => "failure", "statuscode" => status, "message" => ""},
        "data" => data
      }
    })
  end
end
