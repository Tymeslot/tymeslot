defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkProviderTest do
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.RoomData

  setup :verify_on_exit!

  @base_url "https://cloud.example.com"
  @talk_api "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4"

  @config %{
    base_url: @base_url,
    username: "alice",
    app_password: "abcde-fghij-klmno-pqrst-uvwxy"
  }

  @start ~U[2030-05-01 10:00:00Z]
  @end_time ~U[2030-05-01 10:30:00Z]

  defp ocs(data, status \\ 200) do
    {:ok, %Req.Response{status: status, body: Jason.encode!(%{"ocs" => %{"data" => data}})}}
  end

  defp capabilities(talk) do
    %{"capabilities" => %{"spreed" => talk}}
  end

  defp event_capabilities(retention_days \\ 28) do
    capabilities(%{
      "version" => "24.0.5",
      "features" => ["conversation-permissions", "unbind-conversation"],
      "config" => %{"conversations" => %{"retention-event" => retention_days}}
    })
  end

  defp config_with_event do
    Map.put(@config, :event_details, %EventDetails{
      summary: "Intro call with Bob",
      start_time: @start,
      end_time: @end_time
    })
  end

  describe "identity" do
    test "declares its type, name and connection-test bucket" do
      assert NextcloudTalkProvider.provider_type() == :nextcloud_talk
      assert NextcloudTalkProvider.display_name() == "Nextcloud Talk"
      assert NextcloudTalkProvider.connection_test_bucket() == :nextcloud_talk
    end

    test "stores the username and app password as encrypted credentials" do
      assert NextcloudTalkProvider.credential_spec() == %{
               required: [:base_url],
               credential_pairs: [
                 {:username, :username_encrypted},
                 {:api_key, :api_key_encrypted}
               ],
               url_fields: [:base_url]
             }
    end

    test "builds its runtime config from the integration and decrypted credentials" do
      integration = %{base_url: @base_url}
      decrypted = %{username: "alice", api_key: "secret-app-password"}

      assert NextcloudTalkProvider.build_config(integration, decrypted, []) == %{
               base_url: @base_url,
               username: "alice",
               app_password: "secret-app-password"
             }
    end
  end

  describe "validate_config/1" do
    test "accepts a complete config without touching the network" do
      expect(Tymeslot.HTTPClientMock, :get, 0, fn _url, _headers, _opts -> ocs(%{}) end)

      assert :ok = NextcloudTalkProvider.validate_config(@config)
    end

    test "requires the username and app password" do
      assert {:error, message} =
               NextcloudTalkProvider.validate_config(Map.delete(@config, :username))

      assert message =~ "username"

      assert {:error, message} =
               NextcloudTalkProvider.validate_config(Map.delete(@config, :app_password))

      assert message =~ "app_password"
    end

    test "rejects a base URL that is not an HTTP(S) URL" do
      assert {:error, _message} =
               NextcloudTalkProvider.validate_config(%{@config | base_url: "not a url"})
    end
  end

  describe "perform_connection_test/1" do
    test "authenticates, checks that Talk is enabled and reports its version" do
      expect(Tymeslot.HTTPClientMock, :get, fn url, headers, opts ->
        assert url == @base_url <> "/ocs/v2.php/cloud/user"
        assert {"ocs-apirequest", "true"} in headers

        assert {"authorization", "Basic " <> Base.encode64("alice:#{@config.app_password}")} in headers

        assert opts[:ssrf_protect] == true
        ocs(%{"id" => "alice"})
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url == @base_url <> "/ocs/v2.php/cloud/capabilities"
        ocs(event_capabilities())
      end)

      assert {:ok, message} = NextcloudTalkProvider.perform_connection_test(@config)
      assert message =~ "24.0.5"
    end

    test "tags rejected credentials as :invalid_api_key" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, {:invalid_api_key, _message}} =
               NextcloudTalkProvider.perform_connection_test(@config)
    end

    test "tags a server without Talk as :unreachable" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(%{"id" => "alice"})
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(%{"capabilities" => %{"core" => %{}}})
      end)

      assert {:error, {:unreachable, message}} =
               NextcloudTalkProvider.perform_connection_test(@config)

      assert message =~ "Talk"
    end

    test "tags a server that does not answer like Nextcloud as :unreachable" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "<html>not nextcloud</html>"}}
      end)

      assert {:error, {:unreachable, _message}} =
               NextcloudTalkProvider.perform_connection_test(@config)
    end

    test "tags a transport failure as :unreachable" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, {:unreachable, _message}} =
               NextcloudTalkProvider.perform_connection_test(@config)
    end

    test "rejects an invalid base URL without touching the network" do
      expect(Tymeslot.HTTPClientMock, :get, 0, fn _url, _headers, _opts -> ocs(%{}) end)

      assert {:error, {:unreachable, _message}} =
               NextcloudTalkProvider.perform_connection_test(%{@config | base_url: "not a url"})
    end
  end

  describe "create_meeting_room/1" do
    test "creates a public event conversation where guests cannot start calls" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(event_capabilities())
      end)

      expect(Tymeslot.HTTPClientMock, :post, fn url, body, headers, _opts ->
        assert url == @talk_api <> "/room"
        assert {"content-type", "application/json"} in headers

        assert Jason.decode!(body) == %{
                 "roomType" => 3,
                 "roomName" => "Intro call with Bob",
                 "objectType" => "event",
                 "objectId" => "#{DateTime.to_unix(@start)}##{DateTime.to_unix(@end_time)}"
               }

        ocs(%{"token" => "abc123xy", "objectType" => "event", "objectId" => "1#2"}, 201)
      end)

      expect(Tymeslot.HTTPClientMock, :put, fn url, body, _headers, _opts ->
        assert url == @talk_api <> "/room/abc123xy/permissions/default"
        permissions = Jason.decode!(body)["permissions"]

        # Joining a call, publishing media and chatting are allowed ...
        for bit <- [4, 16, 32, 64, 128, 256], do: assert(Bitwise.band(permissions, bit) == bit)
        # ... starting one is not.
        assert Bitwise.band(permissions, 2) == 0

        ocs(%{"token" => "abc123xy"})
      end)

      assert {:ok, %RoomData{} = room} =
               NextcloudTalkProvider.create_meeting_room(config_with_event())

      assert room.room_id == "abc123xy"
      assert room.meeting_url == "https://cloud.example.com/index.php/call/abc123xy"
    end

    test "falls back to a plain public conversation when the server has no event conversations" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(capabilities(%{"features" => ["conversation-permissions"], "config" => %{}}))
      end)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, body, _headers, _opts ->
        assert Jason.decode!(body) == %{"roomType" => 3, "roomName" => "Intro call with Bob"}
        ocs(%{"token" => "plain123"}, 201)
      end)

      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts -> ocs(%{}) end)

      assert {:ok, %RoomData{room_id: "plain123"}} =
               NextcloudTalkProvider.create_meeting_room(config_with_event())
    end

    test "creates a plain conversation when the booking has no time" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(event_capabilities())
      end)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "objectType")
        assert decoded["roomName"] == "Tymeslot"
        ocs(%{"token" => "notime12"}, 201)
      end)

      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts -> ocs(%{}) end)

      assert {:ok, %RoomData{room_id: "notime12"}} =
               NextcloudTalkProvider.create_meeting_room(@config)
    end

    test "trailing slashes in the base URL do not end up in the link" do
      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url == @base_url <> "/ocs/v2.php/cloud/capabilities"
        ocs(event_capabilities())
      end)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        ocs(%{"token" => "slash123"}, 201)
      end)

      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts -> ocs(%{}) end)

      config = %{config_with_event() | base_url: @base_url <> "/"}

      assert {:ok, %RoomData{meeting_url: "https://cloud.example.com/index.php/call/slash123"}} =
               NextcloudTalkProvider.create_meeting_room(config)
    end

    test "removes the conversation again when its permissions cannot be restricted" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(event_capabilities())
      end)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        ocs(%{"token" => "orphan12"}, 201)
      end)

      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 503, body: ""}}
      end)

      expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
        assert url == @talk_api <> "/room/orphan12"
        ocs(nil)
      end)

      assert {:error, {:http_error, 503}} =
               NextcloudTalkProvider.create_meeting_room(config_with_event())
    end

    test "reports rejected credentials in the shape the room worker discards" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, {:unauthorized, _details}} =
               NextcloudTalkProvider.create_meeting_room(config_with_event())
    end

    test "rejects a conversation without a token" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(event_capabilities())
      end)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts -> ocs(%{}, 201) end)

      assert {:error, :invalid_room_response} =
               NextcloudTalkProvider.create_meeting_room(config_with_event())
    end
  end

  describe "update_meeting_room/2" do
    defp room_bound_to(end_time) do
      %{"token" => "abc123xy", "objectType" => "event", "objectId" => "1000##{end_time}"}
    end

    defp update_config(new_end) do
      Map.merge(@config, %{meeting_start_time: new_end, meeting_end_time: new_end})
    end

    test "leaves the conversation bound when the new end is within the retention window" do
      stored_end = DateTime.to_unix(@end_time)

      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url == @talk_api <> "/room/abc123xy"
        ocs(room_bound_to(stored_end))
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(event_capabilities(28))
      end)

      expect(Tymeslot.HTTPClientMock, :delete, 0, fn _url, _headers, _opts -> ocs(nil) end)

      new_end = DateTime.add(@end_time, 26, :day)
      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", update_config(new_end))
    end

    test "detaches the conversation from its event when it could expire before the meeting" do
      stored_end = DateTime.to_unix(@end_time)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(room_bound_to(stored_end))
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(event_capabilities(28))
      end)

      expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
        assert url == @talk_api <> "/room/abc123xy/object"
        ocs(%{"token" => "abc123xy"})
      end)

      # Past the 28-day retention less the one-day safety margin.
      new_end = DateTime.add(@end_time, 27 * 86_400 + 1, :second)
      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", update_config(new_end))
    end

    test "does not detach when the server never expires event conversations" do
      stored_end = DateTime.to_unix(@end_time)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(room_bound_to(stored_end))
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(event_capabilities(0))
      end)

      expect(Tymeslot.HTTPClientMock, :delete, 0, fn _url, _headers, _opts -> ocs(nil) end)

      new_end = DateTime.add(@end_time, 365, :day)
      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", update_config(new_end))
    end

    test "does not detach when the server cannot unbind conversations" do
      stored_end = DateTime.to_unix(@end_time)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(room_bound_to(stored_end))
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(
          capabilities(%{
            "features" => [],
            "config" => %{"conversations" => %{"retention-event" => 28}}
          })
        )
      end)

      expect(Tymeslot.HTTPClientMock, :delete, 0, fn _url, _headers, _opts -> ocs(nil) end)

      new_end = DateTime.add(@end_time, 60, :day)
      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", update_config(new_end))
    end

    test "does nothing for a conversation that is not bound to an event" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        ocs(%{"token" => "abc123xy", "objectType" => "", "objectId" => ""})
      end)

      new_end = DateTime.add(@end_time, 60, :day)
      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", update_config(new_end))
    end

    test "treats a conversation that no longer exists as nothing to update" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      new_end = DateTime.add(@end_time, 60, :day)
      assert :ok = NextcloudTalkProvider.update_meeting_room("abc123xy", update_config(new_end))
    end

    test "surfaces a server error so the sync job retries" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 502, body: ""}}
      end)

      new_end = DateTime.add(@end_time, 60, :day)

      assert {:error, {:http_error, 502}} =
               NextcloudTalkProvider.update_meeting_room("abc123xy", update_config(new_end))
    end
  end

  describe "delete_meeting_room/2" do
    test "deletes the conversation" do
      expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
        assert url == @talk_api <> "/room/abc123xy"
        ocs(nil)
      end)

      assert :ok = NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "treats an already deleted conversation as deleted" do
      expect(Tymeslot.HTTPClientMock, :delete, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert :ok = NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end

    test "surfaces a refusal" do
      expect(Tymeslot.HTTPClientMock, :delete, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: ""}}
      end)

      assert {:error, {:http_error, 403, _body}} =
               NextcloudTalkProvider.delete_meeting_room("abc123xy", @config)
    end
  end

  describe "links" do
    test "hands every participant the same public link" do
      room = %RoomData{
        room_id: "abc123xy",
        provider_data: %{},
        meeting_url: "https://cloud.example.com/index.php/call/abc123xy"
      }

      for role <- ["organizer", "participant"] do
        assert {:ok, "https://cloud.example.com/index.php/call/abc123xy"} =
                 NextcloudTalkProvider.create_join_url(
                   room,
                   "Bob",
                   "bob@example.com",
                   role,
                   @start
                 )
      end
    end

    test "extracts the token from both link forms" do
      assert NextcloudTalkProvider.extract_room_id(
               "https://cloud.example.com/index.php/call/abc123xy"
             ) ==
               "abc123xy"

      assert NextcloudTalkProvider.extract_room_id("https://cloud.example.com/call/abc123xy/") ==
               "abc123xy"

      assert NextcloudTalkProvider.extract_room_id("https://cloud.example.com/apps/files") == nil
      assert NextcloudTalkProvider.extract_room_id(nil) == nil
    end

    test "recognises Talk conversation links" do
      assert NextcloudTalkProvider.valid_meeting_url?(
               "https://cloud.example.com/index.php/call/abc123xy"
             )

      refute NextcloudTalkProvider.valid_meeting_url?("https://cloud.example.com/")
      refute NextcloudTalkProvider.valid_meeting_url?("ftp://cloud.example.com/call/abc123xy")
      refute NextcloudTalkProvider.valid_meeting_url?(nil)
    end
  end
end
