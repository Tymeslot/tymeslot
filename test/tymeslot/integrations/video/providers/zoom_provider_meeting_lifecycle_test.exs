defmodule Tymeslot.Integrations.Video.Providers.ZoomProviderMeetingLifecycleTest do
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
        assert decoded["start_time"] == DateTime.to_iso8601(config.meeting_start_time)

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

      assert {:error, {:http_error, 401, message}} =
               ZoomProvider.update_meeting_room("123", config)

      assert String.contains?(message, "Invalid access token")
    end

    test "forces a real refresh on 401 even when the DB token is within the buffer, then retries" do
      # Regression: previously the post-401 refresh went through the validity
      # double-check, which — seeing the DB token still inside the 300s buffer —
      # returned the SAME rejected token and the retry 401'd again, wrongly
      # forcing the user to reconnect. The forced path must hit OAuth and retry
      # with the genuinely-new token.
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "server-side-revoked-token",
          refresh_token: "valid_refresh",
          # Comfortably valid by the buffer's reckoning — the bug's trigger.
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting meeting:update:meeting"
        })

      config = %{
        access_token: "server-side-revoked-token",
        refresh_token: "valid_refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "meeting:write:meeting meeting:update:meeting",
        integration_id: integration.id,
        user_id: user.id,
        meeting_topic: "Test Meeting",
        meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      # First PATCH with the revoked token returns 401.
      expect(HTTPClientMock, :request, fn :patch, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer server-side-revoked-token"} in headers

        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"code" => 124, "message" => "Invalid access token"})
         }}
      end)

      # The forced refresh MUST call OAuth despite the DB token looking valid.
      expect(ZoomOAuthHelperMock, :refresh_access_token, fn "valid_refresh", nil ->
        {:ok,
         %{
           access_token: "genuinely_new_token",
           refresh_token: "new_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
           scope: "meeting:write:meeting meeting:update:meeting"
         }}
      end)

      # Retry with the fresh token succeeds.
      expect(HTTPClientMock, :request, fn :patch, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer genuinely_new_token"} in headers
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.update_meeting_room("123456789", config)
    end

    test "returns :meeting_not_found when retry after 401 receives 404" do
      # Regression: if the meeting was deleted on Zoom between the first PATCH
      # attempt (401) and the post-refresh retry, the retry's 404 must map to
      # :meeting_not_found — not a generic error that causes Oban retries.
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      # First PATCH returns 401 — token rejected server-side.
      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"code" => 124, "message" => "Invalid access token"})
         }}
      end)

      # Token refresh succeeds.
      expect(ZoomOAuthHelperMock, :refresh_access_token, fn _refresh, nil ->
        {:ok,
         %{
           access_token: "refreshed_token",
           refresh_token: "new_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
         }}
      end)

      # Retry PATCH with fresh token — meeting was deleted on Zoom in the
      # meantime, so Zoom returns 404.
      expect(HTTPClientMock, :request, fn :patch, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer refreshed_token"} in headers

        {:ok,
         %Req.Response{
           status: 404,
           body: Jason.encode!(%{"code" => 3001, "message" => "Meeting does not exist"})
         }}
      end)

      assert {:error, :meeting_not_found} = ZoomProvider.update_meeting_room("123", config)
    end

    test "returns error on network failure" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = ZoomProvider.update_meeting_room("123", config)
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
          oauth_scope: "meeting:write:meeting meeting:update:meeting"
        })

      config = %{
        access_token: "expired_token",
        refresh_token: "valid_refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        oauth_scope: "meeting:write:meeting meeting:update:meeting",
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
           scope: "meeting:write:meeting meeting:update:meeting"
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

    test "refuses a grant lacking the update scope without calling Zoom" do
      # Zoom's granular model separates creating a meeting from changing one:
      # `meeting:write:meeting` does not authorise a PATCH. The gap must be
      # caught here, not sent to Zoom to come back as a 4711.
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "valid_token",
          refresh_token: "valid_refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting meeting:read:meeting meeting:delete:meeting"
        })

      config =
        Map.merge(valid_config(), %{
          oauth_scope: "meeting:write:meeting meeting:read:meeting meeting:delete:meeting",
          integration_id: integration.id,
          user_id: user.id
        })

      # No HTTPClientMock expectation: Mox fails the test if a request is made,
      # which is the assertion that the pre-flight short-circuits.
      assert {:error, :insufficient_scope} =
               ZoomProvider.update_meeting_room("123456789", config)

      # Tymeslot does not request `meeting:update:meeting` today, so no grant
      # holds it and reconnecting would produce the same scopes. Putting
      # "Reconnect required" on the dashboard would be an errand with no end.
      {:ok, reloaded} = VideoIntegrationQueries.get(integration.id)
      refute reloaded.needs_reauth
    end

    test "accepts a classic meeting:write grant for the update" do
      # Classic apps hold one coarse scope covering create, update and delete
      # alike, so a classic grant must not be held to the granular update scope.
      config = %{valid_config() | oauth_scope: "meeting:write meeting:read user:read"}

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ZoomProvider.update_meeting_room("123456789", config)
    end

    test "maps a 4711 on the first PATCH to :insufficient_scope without retrying" do
      # The stored scope satisfies the pre-flight, so the request goes out and
      # Zoom rejects the *grant*. Recognising 4711 on the first attempt is what
      # stops a permanent authorisation gap being retried as though it were a
      # transient failure, and is what silenced the admin alerts.
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "valid_token",
          refresh_token: "valid_refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting meeting:update:meeting"
        })

      config =
        Map.merge(valid_config(), %{
          integration_id: integration.id,
          user_id: user.id
        })

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => 4711,
               "message" =>
                 "Invalid access token, does not contain scopes:" <>
                   "[meeting:update:meeting:admin, meeting:update:meeting]."
             })
         }}
      end)

      assert {:error, :insufficient_scope} =
               ZoomProvider.update_meeting_room("123456789", config)

      # Same reasoning as the pre-flight case: an update scope Tymeslot never
      # asks for is not something the account owner can grant.
      {:ok, reloaded} = VideoIntegrationQueries.get(integration.id)
      refute reloaded.needs_reauth
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

    test "maps Zoom's 4711 scope rejection to :insufficient_scope and flags reauth" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "valid_token",
          refresh_token: "valid_refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          # The stored scope looks sufficient, so validation passes and the
          # request goes out — this is the token whose *grant* at Zoom predates
          # the scope being added.
          oauth_scope: "meeting:write:meeting meeting:delete:meeting"
        })

      config =
        Map.merge(valid_config(), %{
          integration_id: integration.id,
          user_id: user.id
        })

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => 4711,
               "message" =>
                 "Invalid access token, does not contain scopes:[meeting:delete:meeting]."
             })
         }}
      end)

      assert {:error, :insufficient_scope} =
               ZoomProvider.delete_meeting_room("123456789", config)

      {:ok, reloaded} = VideoIntegrationQueries.get(integration.id)
      assert reloaded.needs_reauth
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

      assert {:error, {:http_error, 401, message}} =
               ZoomProvider.delete_meeting_room("123", config)

      assert String.contains?(message, "Invalid access token")
    end

    test "returns error on network failure" do
      config = valid_config()

      expect(ZoomOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = ZoomProvider.delete_meeting_room("123", config)
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
          oauth_scope: "meeting:write:meeting meeting:delete:meeting"
        })

      config = %{
        access_token: "expired_token",
        refresh_token: "valid_refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        oauth_scope: "meeting:write:meeting meeting:delete:meeting",
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
           scope: "meeting:write:meeting meeting:update:meeting"
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
      oauth_scope:
        "meeting:write:meeting meeting:update:meeting meeting:read:meeting meeting:delete:meeting user:read:user",
      meeting_topic: "Test Meeting",
      meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
      meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
    }
  end
end
