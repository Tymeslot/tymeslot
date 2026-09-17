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

    test "refuses a server and login too long to store together" do
      long_server = "https://cloud.example.com/" <> String.duplicate("a", 230)

      assert {:error, message} =
               NextcloudTalkProvider.validate_config(%{@config | base_url: long_server})

      assert message =~ "too long"
    end
  end

  describe "account_attrs/1" do
    test "trims the server and login and keys the account on both" do
      attrs =
        NextcloudTalkProvider.account_attrs(%{
          name: "Team Talk",
          base_url: " https://cloud.example.com/ ",
          client_id: " organiser "
        })

      assert attrs.base_url == @server
      assert attrs.client_id == "organiser"
      assert attrs.provider_account_id == "https://cloud.example.com||organiser"
      assert attrs.name == "Team Talk"
    end
  end

  describe "create_meeting_room/1" do
    test "creates a public conversation named after the booking, its lobby lifting at the start" do
      expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
        assert Jason.decode!(body) == %{
                 "roomType" => 3,
                 "roomName" => "Intro call",
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

    test "a server that restricts who may create conversations is a configuration error" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: ocs([])}}
      end)

      assert {:error, {:configuration_error, :conversation_creation_restricted}} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end

    test "a server that enforces passwords on public conversations is a configuration error" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: ocs(%{"error" => "password"})}}
      end)

      assert {:error, {:configuration_error, :password_required}} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end

    test "a refusal without an error key is still a configuration error" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: ocs(nil)}}
      end)

      assert {:error, {:configuration_error, {:rejected, nil}}} =
               NextcloudTalkProvider.create_meeting_room(with_event(@config))
    end

    test "a server throttling Tymeslot's address is a rate limit to back off from" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: ""}}
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
  end

  describe "perform_connection_test/1" do
    test "succeeds against a Talk that can create configured conversations" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        capabilities(%{"version" => "25.0.0", "features" => ["conversation-creation-all"]})
      end)

      assert {:ok, message} = NextcloudTalkProvider.perform_connection_test(@config)
      assert message =~ "25.0.0"
    end

    test "refuses a Talk too old to set the lobby when creating a conversation" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        capabilities(%{"version" => "20.0.0", "features" => ["chat-v2"]})
      end)

      assert {:error, {:unreachable, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "21.1"
    end

    test "refuses a server where Talk is not available to the account" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ocs(%{"capabilities" => %{"core" => %{}}})}}
      end)

      assert {:error, {:unreachable, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "Talk app"
    end

    test "reports a refused app password against the password" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, {:unauthorized, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "app password"
    end

    test "asks the user to wait when the server is throttling Tymeslot's address" do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: ""}}
      end)

      assert {:error, {:unreachable, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "Wait a few minutes"
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

  defp with_event(config) do
    Map.put(config, :event_details, %EventDetails{
      summary: "Intro call",
      start_time: @start,
      end_time: DateTime.add(@start, 1800, :second)
    })
  end

  defp created(data), do: {:ok, %Req.Response{status: 201, body: ocs(data)}}

  defp capabilities(spreed),
    do: {:ok, %Req.Response{status: 200, body: ocs(%{"capabilities" => %{"spreed" => spreed}})}}

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
end
