defmodule Tymeslot.Integrations.Video.Providers.ZoomProviderMeetingLifecycleTest do
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

  describe "update_meeting_room/2" do
    test "PATCHes Zoom with new times and returns :ok on 204" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, url, body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/123456789"

        assert {"Authorization", "Bearer valid_token"} in headers

        decoded = Jason.decode!(body)
        assert decoded["topic"] == "Test Meeting"
        assert decoded["type"] == 2
        assert decoded["timezone"] == "UTC"
        # Default valid_config uses a 30-minute window
        assert decoded["duration"] == 30
        assert is_binary(decoded["start_time"])

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.update_meeting_room("123456789", config)
    end

    test "returns :meeting_not_found when Zoom returns 404" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 404,
           body: Jason.encode!(%{"code" => 3001, "message" => "Meeting does not exist"})
         }}
      end)

      assert {:error, :meeting_not_found} =
               ZoomProvider.update_meeting_room("999", config)
    end

    test "returns structured error on Zoom API 401 after refresh retry" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      # First PATCH returns 401, triggering a token refresh and retry.
      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"code" => 124, "message" => "Invalid access token"})
         }}
      end)

      # Refresh succeeds but Zoom still rejects the second attempt.
      expect(ZoomOAuthHelperMock, :refresh_access_token, fn _refresh, nil ->
        {:ok,
         %{
           access_token: "refreshed_token",
           refresh_token: "new_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
         }}
      end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer refreshed_token"} in headers

        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"code" => 124, "message" => "Invalid access token"})
         }}
      end)

      assert {:error, message} = ZoomProvider.update_meeting_room("123", config)
      assert String.contains?(message, "401")
      assert String.contains?(message, "Invalid access token")
    end

    test "returns error on network failure" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, message} = ZoomProvider.update_meeting_room("123", config)
      assert String.contains?(message, "Network error")
    end

    test "rejects malformed meeting_start_time without making an HTTP call" do
      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      config = Map.put(valid_config(), :meeting_start_time, "not-a-real-date")

      assert {:error, msg} = ZoomProvider.update_meeting_room("123", config)
      assert msg =~ "Invalid datetime"
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

      expect(HTTPClientMock, :request, fn :patch, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer new_token"} in headers

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.update_meeting_room("123456789", config)

      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_token"
      assert decrypted.refresh_token == "new_refresh"
    end

    test "returns error and skips HTTP call when validate_token returns an error" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:error, "expired"} end)

      assert {:error, message} = ZoomProvider.update_meeting_room("123456789", config)
      assert String.contains?(message, "Token validation failed")
      assert String.contains?(message, "expired")
    end
  end

  describe "delete_meeting_room/2" do
    test "DELETEs Zoom meeting and returns :ok on 204" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/123456789"
        assert body == ""
        assert {"Authorization", "Bearer valid_token"} in headers

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.delete_meeting_room("123456789", config)
    end

    test "treats 404 as success so cancellation is idempotent" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 404,
           body: Jason.encode!(%{"code" => 3001, "message" => "Meeting does not exist"})
         }}
      end)

      assert :ok = ZoomProvider.delete_meeting_room("gone", config)
    end

    test "returns structured error on Zoom API 401 after refresh retry" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      # First DELETE returns 401, triggering a token refresh and retry.
      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"code" => 124, "message" => "Invalid access token"})
         }}
      end)

      # Refresh succeeds but Zoom still rejects the second attempt.
      expect(ZoomOAuthHelperMock, :refresh_access_token, fn _refresh, nil ->
        {:ok,
         %{
           access_token: "refreshed_token",
           refresh_token: "new_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
         }}
      end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer refreshed_token"} in headers

        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"code" => 124, "message" => "Invalid access token"})
         }}
      end)

      assert {:error, message} = ZoomProvider.delete_meeting_room("123", config)
      assert String.contains?(message, "401")
    end

    test "returns error on network failure" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, message} = ZoomProvider.delete_meeting_room("123", config)
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

      expect(HTTPClientMock, :request, fn :delete, url, body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/123456789"
        assert body == ""
        assert {"Authorization", "Bearer new_token"} in headers

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.delete_meeting_room("123456789", config)

      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_token"
      assert decrypted.refresh_token == "new_refresh"
    end

    test "returns error and skips HTTP call when validate_token returns an error" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:error, "expired"} end)

      assert {:error, message} = ZoomProvider.delete_meeting_room("123456789", config)
      assert String.contains?(message, "Token validation failed")
      assert String.contains?(message, "expired")
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
