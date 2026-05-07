defmodule Tymeslot.Integrations.Video.Providers.ZoomProviderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  describe "provider_type/0" do
    test "returns :zoom" do
      assert ZoomProvider.provider_type() == :zoom
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert ZoomProvider.display_name() == "Zoom"
    end
  end

  describe "config_schema/0" do
    test "returns schema with required OAuth fields" do
      schema = ZoomProvider.config_schema()

      assert schema[:access_token][:required] == true
      assert schema[:refresh_token][:required] == true
      assert schema[:token_expires_at][:required] == true
    end
  end

  describe "capabilities/0" do
    test "returns correct capabilities for Zoom" do
      capabilities = ZoomProvider.capabilities()

      assert capabilities[:supports_scheduled_meetings] == true
      assert capabilities[:supports_recurring_meetings] == true
      assert capabilities[:supports_waiting_room] == true
      assert capabilities[:max_participants] == 100
      assert capabilities[:requires_account] == true
      assert capabilities[:requires_work_account] == false
    end
  end

  describe "validate_config/1" do
    test "returns error when access_token is missing" do
      config = %{refresh_token: "r", token_expires_at: DateTime.utc_now()}
      assert {:error, message} = ZoomProvider.validate_config(config)
      assert String.contains?(message, "access_token")
    end

    test "returns :ok when all required fields present" do
      config = %{
        access_token: "a",
        refresh_token: "r",
        token_expires_at: DateTime.utc_now()
      }

      assert :ok = ZoomProvider.validate_config(config)
    end
  end

  describe "test_connection/1" do
    test "returns success when token validates" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      assert {:ok, message} = ZoomProvider.test_connection(config)
      assert String.contains?(message, "Successfully authenticated")
    end

    test "returns error when token validation fails" do
      config = %{access_token: "bad"}

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:error, "expired"} end)

      assert {:error, message} = ZoomProvider.test_connection(config)
      assert String.contains?(message, "Failed to authenticate")
      assert String.contains?(message, "expired")
    end
  end

  describe "create_meeting_room/1" do
    test "returns room data on success" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, url, body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/users/me/meetings"

        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and v == "Bearer valid_token"
               end)

        decoded = Jason.decode!(body)
        assert decoded["topic"] == "Test Meeting"
        assert decoded["type"] == 2
        assert decoded["timezone"] == "UTC"
        assert decoded["settings"]["waiting_room"] == true
        assert decoded["settings"]["join_before_host"] == false
        assert decoded["settings"]["mute_upon_entry"] == true

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => 123_456_789,
               "join_url" => "https://zoom.us/j/123456789",
               "start_url" => "https://zoom.us/s/123456789?zak=abc",
               "password" => "p4ss",
               "host_email" => "alice@example.com"
             })
         }}
      end)

      assert {:ok, room} = ZoomProvider.create_meeting_room(config)
      assert room.room_id == "123456789"
      assert room.meeting_url == "https://zoom.us/j/123456789"
      assert room.provider_data.passcode == "p4ss"
      assert String.contains?(room.provider_data.start_url, "/s/123456789")
      assert room.provider_data.host_email == "alice@example.com"
    end

    test "returns structured error on Zoom API 401" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"code" => 124, "message" => "Invalid access token"})
         }}
      end)

      assert {:error, message} = ZoomProvider.create_meeting_room(config)
      assert String.contains?(message, "Invalid access token")
      assert String.contains?(message, "401")
      assert String.contains?(message, "124")
    end

    test "returns error when response is missing join_url" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 201, body: Jason.encode!(%{"id" => 999})}}
      end)

      assert {:error, message} = ZoomProvider.create_meeting_room(config)
      assert String.contains?(message, "missing")
    end

    test "returns error when response body is invalid JSON" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 201, body: "not valid json{{"}}
      end)

      assert {:error, message} = ZoomProvider.create_meeting_room(config)
      assert String.contains?(message, "Invalid JSON")
    end

    test "returns error on network failure" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, message} = ZoomProvider.create_meeting_room(config)
      assert String.contains?(message, "Network error")
    end

    test "refreshes token when validate_token returns :needs_refresh and persists to database" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "expired_token",
          refresh_token: "valid_refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          oauth_scope: "meeting:write:meeting"
        })

      config = %{
        access_token: "expired_token",
        refresh_token: "valid_refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        integration_id: integration.id,
        user_id: user.id,
        meeting_topic: "Test Meeting",
        meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :needs_refresh} end)

      expect(ZoomOAuthHelperMock, :refresh_access_token, fn "valid_refresh", nil ->
        {:ok,
         %{
           access_token: "new_token",
           refresh_token: "new_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
           scope: "meeting:write:meeting"
         }}
      end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer new_token"} in headers

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => 999,
               "join_url" => "https://zoom.us/j/999",
               "start_url" => "https://zoom.us/s/999",
               "password" => nil,
               "host_email" => nil
             })
         }}
      end)

      assert {:ok, room} = ZoomProvider.create_meeting_room(config)
      assert room.room_id == "999"

      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_token"
      assert decrypted.refresh_token == "new_refresh"
    end

    test "refresh path without integration_id/user_id bypasses persistence" do
      config = Map.put(valid_config(), :access_token, "expired")

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :needs_refresh} end)

      expect(ZoomOAuthHelperMock, :refresh_access_token, fn _refresh, nil ->
        {:ok,
         %{
           access_token: "fresh_token",
           refresh_token: "fresh_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
         }}
      end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer fresh_token"} in headers

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => 555,
               "join_url" => "https://zoom.us/j/555",
               "start_url" => "https://zoom.us/s/555",
               "password" => nil,
               "host_email" => nil
             })
         }}
      end)

      assert {:ok, room} = ZoomProvider.create_meeting_room(config)
      assert room.room_id == "555"
    end

    test "skips refresh and uses fresh DB token when token already refreshed concurrently" do
      user = insert(:user)
      fresh_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "fresh-token-from-other-process",
          refresh_token: "ref",
          token_expires_at: fresh_expiry,
          oauth_scope: "meeting:write:meeting"
        })

      config = %{
        access_token: "stale-token-current-process",
        refresh_token: "ref",
        token_expires_at: DateTime.add(DateTime.utc_now(), -10, :second),
        integration_id: integration.id,
        user_id: user.id,
        meeting_topic: "Concurrent test",
        meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      # Stub: validate_token says we need to refresh (current process's view)
      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :needs_refresh} end)

      # We expect refresh_access_token NOT to be called: another process already
      # refreshed. The HTTP call should use the fresh DB token.
      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer fresh-token-from-other-process"} in headers

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => 111,
               "join_url" => "https://zoom.us/j/111",
               "start_url" => "https://zoom.us/s/111",
               "password" => nil,
               "host_email" => nil
             })
         }}
      end)

      assert {:ok, _room} = ZoomProvider.create_meeting_room(config)
    end

    test "falls back to direct refresh when integration disappears mid-flight" do
      config = %{
        access_token: "stale",
        refresh_token: "ref",
        token_expires_at: DateTime.add(DateTime.utc_now(), -10, :second),
        # nonexistent
        integration_id: 9_999_999,
        user_id: 9_999_999,
        meeting_topic: "Vanished integration",
        meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :needs_refresh} end)

      # Refresh IS called because the integration vanished and we can't
      # double-check.
      expect(ZoomOAuthHelperMock, :refresh_access_token, fn "ref", _scope ->
        {:ok,
         %{
           access_token: "after-refresh",
           refresh_token: "new-ref",
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
           scope: "meeting:write:meeting"
         }}
      end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer after-refresh"} in headers

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => 222,
               "join_url" => "https://zoom.us/j/222",
               "start_url" => "https://zoom.us/s/222",
               "password" => nil,
               "host_email" => nil
             })
         }}
      end)

      assert {:ok, _room} = ZoomProvider.create_meeting_room(config)
    end

    test "returns error tuple for malformed meeting_start_time" do
      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      config = %{
        access_token: "tok",
        refresh_token: "ref",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_topic: "Bad time",
        meeting_start_time: "not-a-real-date",
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      assert {:error, msg} = ZoomProvider.create_meeting_room(config)
      assert msg =~ "Invalid datetime"
      refute msg =~ "MatchError"
    end
  end

  describe "create_join_url/5" do
    test "appends uname query parameter when URL has no existing query" do
      room_data = %{meeting_url: "https://zoom.us/j/123456789"}

      assert {:ok, url} =
               ZoomProvider.create_join_url(room_data, "John Doe", "j@x", "attendee", nil)

      assert String.contains?(url, "?uname=John")
    end

    test "appends uname using ampersand when URL already has query string" do
      room_data = %{meeting_url: "https://zoom.us/j/123456789?pwd=abc"}

      assert {:ok, url} =
               ZoomProvider.create_join_url(room_data, "Alice", "a@x", "host", nil)

      assert String.contains?(url, "&uname=Alice")
    end

    test "returns error when meeting_url is nil" do
      room_data = %{meeting_url: nil}

      assert {:error, message} =
               ZoomProvider.create_join_url(room_data, "Bob", "b@x", "attendee", nil)

      assert String.contains?(message, "Missing meeting URL")
    end
  end

  describe "extract_room_id/1" do
    test "parses numeric ID from a standard /j/ URL" do
      assert ZoomProvider.extract_room_id("https://zoom.us/j/987654321") == "987654321"
    end

    test "returns nil for vanity /my/ URLs without numeric ID" do
      assert ZoomProvider.extract_room_id("https://zoom.us/my/johndoe") == nil
    end

    test "returns nil for non-zoom URLs" do
      assert ZoomProvider.extract_room_id("https://meet.google.com/abc-defg-hij") == nil
    end

    test "extracts room_id from a struct-style room_data map" do
      assert ZoomProvider.extract_room_id(%{room_data: %{room_id: "abc"}}) == "abc"
    end

    test "returns nil for unrecognised input" do
      assert ZoomProvider.extract_room_id(%{}) == nil
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts zoom.us subdomains" do
      assert ZoomProvider.valid_meeting_url?("https://zoom.us/j/123")
      assert ZoomProvider.valid_meeting_url?("https://us02web.zoom.us/j/123")
    end

    test "rejects other providers" do
      refute ZoomProvider.valid_meeting_url?("https://meet.google.com/abc")
      refute ZoomProvider.valid_meeting_url?("https://teams.microsoft.com/l/meetup-join/abc")
    end
  end

  describe "handle_meeting_event/3" do
    test "returns :ok for meeting_ended event" do
      assert ZoomProvider.handle_meeting_event(:meeting_ended, %{room_id: "1"}, %{}) == :ok
    end

    test "returns :ok for unknown events" do
      assert ZoomProvider.handle_meeting_event(:unknown, %{}, %{}) == :ok
    end
  end

  describe "generate_meeting_metadata/1" do
    test "returns metadata with Zoom-specific keys" do
      room_data = %{
        room_id: "123",
        meeting_url: "https://zoom.us/j/123",
        provider_data: %{passcode: "p4ss", start_url: "https://zoom.us/s/123"}
      }

      metadata = ZoomProvider.generate_meeting_metadata(room_data)

      assert metadata[:provider] == "zoom"
      assert metadata[:meeting_id] == "123"
      assert metadata[:passcode] == "p4ss"
      assert metadata[:host_url] == "https://zoom.us/s/123"
    end
  end

  defp valid_config do
    %{
      access_token: "valid_token",
      refresh_token: "valid_refresh",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      meeting_topic: "Test Meeting",
      meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
      meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
    }
  end
end
