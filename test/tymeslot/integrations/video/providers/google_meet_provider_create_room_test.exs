defmodule Tymeslot.Integrations.Video.Providers.GoogleMeetProviderCreateRoomTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.GoogleOAuthHelperMock
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.GoogleMeetProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  describe "create_meeting_room/1" do
    test "creates a standalone Meet space and returns the space id and join URL" do
      config = %{
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      # The Meet REST API is called — not the Calendar API — and no calendar
      # event payload is sent (an empty body provisions a default space).
      expect(HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url == "https://meet.googleapis.com/v2/spaces"
        assert body == "{}"
        {:ok, %Req.Response{status: 200, body: Jason.encode!(space_response())}}
      end)

      assert {:ok, room_data} = GoogleMeetProvider.create_meeting_room(config)

      # room_id is the space id (the segment after "spaces/"), which is what
      # endActiveConference requires on cancellation — not the meeting code.
      assert room_data.room_id == "NgPxrxVDQF8B"
      assert room_data.meeting_url == "https://meet.google.com/abc-defg-hij"
    end

    test "returns error when API response is malformed JSON" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "not valid json{{"}}
      end)

      assert {:error, message} = GoogleMeetProvider.create_meeting_room(config)
      assert message =~ "Invalid JSON"
    end

    test "returns error when the space response has no meeting URL" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"name" => "spaces/abc123"})}}
      end)

      assert {:error, message} = GoogleMeetProvider.create_meeting_room(config)
      assert message =~ "did not return a meeting URL"
    end

    test "returns error when the space response has no space identifier" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"meetingUri" => "https://meet.google.com/abc-defg-hij"})
         }}
      end)

      assert {:error, message} = GoogleMeetProvider.create_meeting_room(config)
      assert message =~ "did not return a space identifier"
    end

    test "surfaces a clear error when the Meet API is disabled (403)" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: ~s({"error":{"status":"SERVICE_DISABLED"}})}}
      end)

      assert {:error, {:http_error, 403, message}} =
               GoogleMeetProvider.create_meeting_room(config)

      assert message =~ "HTTP 403"
    end

    test "ignores :event_details — no calendar event payload is sent" do
      config =
        Map.put(valid_token_config(), :event_details, %{
          summary: "Quarterly Review",
          attendees: [%{email: "alice@example.com"}]
        })

      expect(HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url == "https://meet.googleapis.com/v2/spaces"
        # No summary/attendees/conferenceData leak into the request.
        assert body == "{}"
        {:ok, %Req.Response{status: 200, body: Jason.encode!(space_response())}}
      end)

      assert {:ok, _room} = GoogleMeetProvider.create_meeting_room(config)
    end

    test "persists refreshed tokens to database" do
      user = insert(:user)
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      new_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          access_token: "expired",
          refresh_token: "refresh",
          token_expires_at: expires_at
        )

      config = %{
        access_token: "expired",
        refresh_token: "refresh",
        token_expires_at: expires_at,
        integration_id: integration.id,
        user_id: user.id
      }

      expect(GoogleOAuthHelperMock, :refresh_access_token, fn "refresh", nil ->
        {:ok,
         %{
           access_token: "new_token",
           refresh_token: "new_refresh",
           expires_at: new_expires_at,
           scope: "new_scope"
         }}
      end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(space_response())}}
      end)

      assert {:ok, _result} = GoogleMeetProvider.create_meeting_room(config)

      # Verify DB update
      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_token"
      assert decrypted.refresh_token == "new_refresh"
      assert updated.oauth_scope == "new_scope"
    end

    test "skips refresh and uses fresh DB token when token already refreshed concurrently" do
      user = insert(:user)
      fresh_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Google Meet",
          provider: "google_meet",
          access_token: "fresh-token-from-other-process",
          refresh_token: "fresh-refresh-from-other-process",
          token_expires_at: fresh_expiry,
          oauth_scope: "calendar.scope"
        })

      config = %{
        access_token: "stale-token-current-process",
        refresh_token: "stale-refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), -10, :second),
        oauth_scope: "calendar.scope",
        integration_id: integration.id,
        user_id: user.id
      }

      # No refresh_access_token expectation: another process already refreshed
      # while we waited on the lock, so the merged config must carry the fresh
      # DB token and the HTTP call must use it.
      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer fresh-token-from-other-process"} in headers
        {:ok, %Req.Response{status: 200, body: Jason.encode!(space_response())}}
      end)

      assert {:ok, _room} = GoogleMeetProvider.create_meeting_room(config)
    end
  end

  # Pins the circuit-breaker split from `ProviderAdapter`: a per-tenant
  # credential failure during token refresh must never reach
  # `finish_create_meeting_room/2` (and so never count against the shared
  # Google Meet breaker), while a provider-host failure during refresh still
  # needs to reach it.
  describe "precheck_create_meeting_room/1" do
    test "bypasses the breaker on a rejected/expired grant" do
      config = %{
        access_token: "expired",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      expect(GoogleOAuthHelperMock, :refresh_access_token, fn "refresh_token", nil ->
        {:error, "Token refresh failed: invalid_grant"}
      end)

      assert {:error, "Failed to refresh token: Token refresh failed: invalid_grant"} =
               GoogleMeetProvider.precheck_create_meeting_room(config)
    end

    test "lets the breaker witness a network/5xx failure from the OAuth host" do
      config = %{
        access_token: "expired",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      expect(GoogleOAuthHelperMock, :refresh_access_token, fn "refresh_token", nil ->
        {:error, "Network error during token refresh: timeout"}
      end)

      assert {:provider_error,
              "Failed to refresh token: Network error during token refresh: timeout"} =
               GoogleMeetProvider.precheck_create_meeting_room(config)
    end

    test "returns {:ok, config} for a still-valid token, doing no refresh" do
      config = valid_token_config()

      assert {:ok, ^config} = GoogleMeetProvider.precheck_create_meeting_room(config)
    end
  end

  describe "finish_create_meeting_room/2" do
    test "makes the outbound Meet API call with the already-resolved config" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, url, _body, headers, _opts ->
        assert url == "https://meet.googleapis.com/v2/spaces"
        assert {"Authorization", "Bearer valid_token"} in headers
        {:ok, %Req.Response{status: 200, body: Jason.encode!(space_response())}}
      end)

      assert {:ok, room_data} = GoogleMeetProvider.finish_create_meeting_room(config, config)
      assert room_data.room_id == "NgPxrxVDQF8B"
    end
  end

  describe "delete_meeting_room/2" do
    test "ends the active conference for the given space id" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url == "https://meet.googleapis.com/v2/spaces/NgPxrxVDQF8B:endActiveConference"
        assert body == "{}"
        {:ok, %Req.Response{status: 200, body: "{}"}}
      end)

      assert :ok = GoogleMeetProvider.delete_meeting_room("NgPxrxVDQF8B", config)
    end

    test "treats 'no active conference' (400) as success" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: ~s({"error":{"status":"FAILED_PRECONDITION"}})}}
      end)

      assert :ok = GoogleMeetProvider.delete_meeting_room("NgPxrxVDQF8B", config)
    end

    test "treats a legacy meeting-code id (403) as a no-op" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: ~s({"error":{"status":"PERMISSION_DENIED"}})}}
      end)

      assert :ok = GoogleMeetProvider.delete_meeting_room("abc-defg-hij", config)
    end

    test "is a no-op when no space id is stored" do
      assert :ok = GoogleMeetProvider.delete_meeting_room(nil, valid_token_config())
      assert :ok = GoogleMeetProvider.delete_meeting_room("", valid_token_config())
    end

    test "returns an error on an unexpected status so the worker can retry" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 500, body: "boom"}}
      end)

      assert {:error, {:http_error, 500, message}} =
               GoogleMeetProvider.delete_meeting_room("NgPxrxVDQF8B", config)

      assert message =~ "HTTP 500"
    end
  end

  # Mirrors the shape returned by POST https://meet.googleapis.com/v2/spaces.
  defp space_response do
    %{
      "name" => "spaces/NgPxrxVDQF8B",
      "meetingUri" => "https://meet.google.com/abc-defg-hij",
      "meetingCode" => "abc-defg-hij"
    }
  end

  defp valid_token_config do
    %{
      access_token: "valid_token",
      refresh_token: "refresh_token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end
end
