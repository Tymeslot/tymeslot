defmodule Tymeslot.Integrations.Video.Providers.ZoomProviderLifecycleTest do
  use Tymeslot.DataCase, async: false
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

  describe "create_meeting_room/1" do
    test "returns room data on success" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, 2, fn
        :post, url, body, headers, _opts ->
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

        :get, url, _body, headers, _opts ->
          # Read-back verification exercises the meeting:read:meeting scope.
          assert url == "https://api.zoom.us/v2/meetings/123456789"

          assert Enum.any?(headers, fn {k, v} ->
                   String.downcase(k) == "authorization" and v == "Bearer valid_token"
                 end)

          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(%{"id" => 123_456_789, "status" => "waiting"})
           }}
      end)

      assert {:ok, room} = ZoomProvider.create_meeting_room(config)
      assert room.room_id == "123456789"
      assert room.meeting_url == "https://zoom.us/j/123456789"
      assert room.provider_data.passcode == "p4ss"
      assert String.contains?(room.provider_data.start_url, "/s/123456789")
      assert room.provider_data.host_email == "alice@example.com"
    end

    test "still returns the room when the read-back verification fails" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, 2, fn
        :post, _url, _body, _headers, _opts ->
          {:ok,
           %Req.Response{
             status: 201,
             body:
               Jason.encode!(%{
                 "id" => 123_456_789,
                 "join_url" => "https://zoom.us/j/123456789"
               })
           }}

        # The meeting already exists, so a failed read-back must not fail the
        # booking — verification is best-effort.
        :get, _url, _body, _headers, _opts ->
          {:error, :timeout}
      end)

      assert {:ok, room} = ZoomProvider.create_meeting_room(config)
      assert room.room_id == "123456789"
      assert room.meeting_url == "https://zoom.us/j/123456789"
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

      assert {:error, {:http_error, 401, message}} = ZoomProvider.create_meeting_room(config)
      assert String.contains?(message, "Invalid access token")
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

      assert {:error, :timeout} = ZoomProvider.create_meeting_room(config)
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
        oauth_scope: "meeting:write:meeting",
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

      expect(HTTPClientMock, :request, 2, fn
        :post, _url, _body, headers, _opts ->
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

        :get, _url, _body, headers, _opts ->
          assert {"Authorization", "Bearer new_token"} in headers
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => 999})}}
      end)

      assert {:ok, room} = ZoomProvider.create_meeting_room(config)
      assert room.room_id == "999"

      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_token"
      assert decrypted.refresh_token == "new_refresh"
    end

    test "keeps the existing refresh token when the refresh response omits a new one" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "expired_token",
          refresh_token: "original_refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          oauth_scope: "meeting:write:meeting"
        })

      config = %{
        access_token: "expired_token",
        refresh_token: "original_refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        oauth_scope: "meeting:write:meeting",
        integration_id: integration.id,
        user_id: user.id,
        meeting_topic: "Test Meeting",
        meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :needs_refresh} end)

      # Zoom returned a new access token but no fresh refresh token (nil).
      expect(ZoomOAuthHelperMock, :refresh_access_token, fn "original_refresh", nil ->
        {:ok,
         %{
           access_token: "new_access_token",
           refresh_token: nil,
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
         }}
      end)

      expect(HTTPClientMock, :request, 2, fn
        :post, _url, _body, _headers, _opts ->
          {:ok,
           %Req.Response{
             status: 201,
             body: Jason.encode!(%{"id" => 321, "join_url" => "https://zoom.us/j/321"})
           }}

        :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => 321})}}
      end)

      assert {:ok, _room} = ZoomProvider.create_meeting_room(config)

      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_access_token"
      # The refresh token must remain the original — never the access token.
      assert decrypted.refresh_token == "original_refresh"
      refute decrypted.refresh_token == "new_access_token"
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

      expect(HTTPClientMock, :request, 2, fn
        :post, _url, _body, headers, _opts ->
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

        :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => 555})}}
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
        oauth_scope: "meeting:write:meeting",
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
      expect(HTTPClientMock, :request, 2, fn
        :post, _url, _body, headers, _opts ->
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

        :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => 111})}}
      end)

      assert {:ok, _room} = ZoomProvider.create_meeting_room(config)
    end

    test "falls back to direct refresh when integration disappears mid-flight" do
      config = %{
        access_token: "stale",
        refresh_token: "ref",
        token_expires_at: DateTime.add(DateTime.utc_now(), -10, :second),
        oauth_scope: "meeting:write:meeting",
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

      expect(HTTPClientMock, :request, 2, fn
        :post, _url, _body, headers, _opts ->
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

        :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => 222})}}
      end)

      assert {:ok, _room} = ZoomProvider.create_meeting_room(config)
    end

    test "uses the booking's start/duration/topic from event_details on the POST body" do
      start_time = DateTime.truncate(DateTime.add(DateTime.utc_now(), 7200, :second), :second)
      end_time = DateTime.add(start_time, 2700, :second)

      config =
        valid_config()
        |> Map.drop([:meeting_topic, :meeting_start_time, :meeting_end_time])
        |> Map.put(:event_details, %Tymeslot.Integrations.Video.EventDetails{
          summary: "Discovery call with Dana",
          start_time: start_time,
          end_time: end_time
        })

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, 2, fn
        :post, _url, body, _headers, _opts ->
          decoded = Jason.decode!(body)
          assert decoded["topic"] == "Discovery call with Dana"
          # 2700s = 45 minutes.
          assert decoded["duration"] == 45
          {:ok, sent_start, _offset} = DateTime.from_iso8601(decoded["start_time"])
          assert DateTime.compare(sent_start, start_time) == :eq

          {:ok,
           %Req.Response{
             status: 201,
             body: Jason.encode!(%{"id" => 42, "join_url" => "https://zoom.us/j/42"})
           }}

        :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => 42})}}
      end)

      assert {:ok, room} = ZoomProvider.create_meeting_room(config)
      assert room.room_id == "42"
    end

    test "returns error tuple for malformed meeting_start_time" do
      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      config = %{
        access_token: "tok",
        refresh_token: "ref",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "meeting:write:meeting",
        meeting_topic: "Bad time",
        meeting_start_time: "not-a-real-date",
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      assert {:error, msg} = ZoomProvider.create_meeting_room(config)
      assert msg =~ "Invalid datetime"
      refute msg =~ "MatchError"
    end
  end

  describe "Zoom scope validation" do
    test "accepts the classic meeting:write scope" do
      config = Map.put(valid_config(), :oauth_scope, "meeting:write user:read")

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, 2, fn
        :post, _url, _body, _headers, _opts ->
          {:ok,
           %Req.Response{
             status: 201,
             body: Jason.encode!(%{"id" => 7, "join_url" => "https://zoom.us/j/7"})
           }}

        :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => 7})}}
      end)

      assert {:ok, _room} = ZoomProvider.create_meeting_room(config)
    end

    test "accepts the granular meeting:write:meeting scope" do
      config = Map.put(valid_config(), :oauth_scope, "meeting:write:meeting user:read:user")

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, 2, fn
        :post, _url, _body, _headers, _opts ->
          {:ok,
           %Req.Response{
             status: 201,
             body: Jason.encode!(%{"id" => 8, "join_url" => "https://zoom.us/j/8"})
           }}

        :get, _url, _body, _headers, _opts ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => 8})}}
      end)

      assert {:ok, _room} = ZoomProvider.create_meeting_room(config)
    end

    test "rejects a config that grants neither meeting-write scope" do
      config = Map.put(valid_config(), :oauth_scope, "user:read:user")

      assert {:error, :insufficient_scope} = ZoomProvider.create_meeting_room(config)
    end

    test "does not accept a longer unrelated scope that merely contains meeting:write" do
      # A scope token like "meeting:write:something_else" is granular-shaped but
      # not the classic token; only an exact classic match or the granular
      # meeting:write:meeting should pass. This guards the whole-token check.
      config = Map.put(valid_config(), :oauth_scope, "meeting:write:registrant")

      assert {:error, :insufficient_scope} = ZoomProvider.create_meeting_room(config)
    end

    test "rejects a delete when the granular grant omits meeting:delete:meeting" do
      # The exact production shape: a token granted before the delete scope was
      # requested. Writes still work, so only the delete path may reject it.
      config = Map.put(valid_config(), :oauth_scope, "meeting:write:meeting user:read:user")

      assert {:error, :insufficient_scope} =
               ZoomProvider.delete_meeting_room("123456789", config)
    end

    test "accepts a delete when a hybrid grant carries classic meeting:write" do
      # Classic meeting:write authorises deletes on its own; granular scopes
      # alongside it must not tighten the check to meeting:delete:meeting.
      config =
        Map.put(valid_config(), :oauth_scope, "meeting:write meeting:write:meeting user:read")

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.delete_meeting_room("123456789", config)
    end

    test "accepts a delete under the classic meeting:write scope" do
      config = Map.put(valid_config(), :oauth_scope, "meeting:write user:read")

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.delete_meeting_room("123456789", config)
    end
  end

  defp valid_config do
    %{
      access_token: "valid_token",
      refresh_token: "valid_refresh",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting meeting:read:meeting user:read:user",
      meeting_topic: "Test Meeting",
      meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
      meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
    }
  end
end
