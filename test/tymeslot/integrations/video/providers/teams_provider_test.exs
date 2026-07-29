defmodule Tymeslot.Integrations.Video.Providers.TeamsProviderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.TeamsOAuthHelperMock

  setup :verify_on_exit!

  describe "provider_type/0" do
    test "returns :teams" do
      assert TeamsProvider.provider_type() == :teams
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert TeamsProvider.display_name() == "Microsoft Teams"
    end
  end

  describe "config_schema/0" do
    test "returns schema with required OAuth fields" do
      schema = TeamsProvider.config_schema()

      assert schema[:access_token][:type] == :string
      assert schema[:access_token][:required] == true
      assert schema[:refresh_token][:type] == :string
      assert schema[:refresh_token][:required] == true
      assert schema[:token_expires_at][:type] == :datetime
      assert schema[:token_expires_at][:required] == true
    end
  end

  describe "capabilities/0" do
    test "returns correct capabilities for Teams" do
      capabilities = TeamsProvider.capabilities()

      assert capabilities[:waiting_room] == true
      assert capabilities[:recording] == true
      assert capabilities[:dial_in] == true
      assert capabilities[:max_participants] == 300
      assert capabilities[:breakout_rooms] == true
      assert capabilities[:screen_sharing] == true
      assert capabilities[:chat] == true
    end
  end

  describe "validate_config/1" do
    test "returns error when access_token is missing" do
      config = %{
        refresh_token: "refresh_token",
        token_expires_at: DateTime.utc_now()
      }

      assert {:error, message} = TeamsProvider.validate_config(config)
      assert String.contains?(message, "access_token")
    end

    test "returns error when refresh_token is missing" do
      config = %{
        access_token: "access_token",
        token_expires_at: DateTime.utc_now()
      }

      assert {:error, message} = TeamsProvider.validate_config(config)
      assert String.contains?(message, "refresh_token")
    end

    test "returns error when token_expires_at is missing" do
      config = %{
        access_token: "access_token",
        refresh_token: "refresh_token"
      }

      assert {:error, message} = TeamsProvider.validate_config(config)
      assert String.contains?(message, "token_expires_at")
    end

    test "returns :ok when all required fields present" do
      config = %{
        access_token: "access_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.utc_now()
      }

      assert :ok = TeamsProvider.validate_config(config)
    end
  end

  describe "test_connection/1" do
    test "returns success when token is valid" do
      config = %{
        access_token: "valid_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      }

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      assert {:ok, message} = TeamsProvider.test_connection(config)
      assert String.contains?(message, "Successfully authenticated")
    end

    test "returns error when token validation fails" do
      config = %{access_token: "invalid_token"}

      expect(TeamsOAuthHelperMock, :validate_token, fn _client -> {:error, "Invalid"} end)

      assert {:error, message} = TeamsProvider.test_connection(config)
      assert String.contains?(message, "Failed to authenticate")
    end
  end

  describe "create_meeting_room/1" do
    test "successfully creates a meeting room" do
      config = %{
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "Calendars.ReadWrite"
      }

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, url, _body, headers, _opts ->
        assert url == "https://graph.microsoft.com/v1.0/me/events"

        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and v == "Bearer valid_token"
               end)

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => "meeting123",
               "onlineMeetingUrl" => "https://teams.microsoft.com/l/meetup-join/abc"
             })
         }}
      end)

      assert {:ok, room_data} = TeamsProvider.create_meeting_room(config)
      assert room_data.room_id == "meeting123"
      assert room_data.meeting_url == "https://teams.microsoft.com/l/meetup-join/abc"
    end

    test "refreshes token and persists to database" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Teams",
          provider: "teams",
          tenant_id: "t1",
          client_id: "c1",
          client_secret: "s1",
          teams_user_id: "u1",
          access_token: "expired",
          refresh_token: "refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600),
          oauth_scope: "Calendars.ReadWrite"
        })

      config = %{
        access_token: "expired",
        refresh_token: "refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600),
        integration_id: integration.id,
        user_id: user.id,
        oauth_scope: "Calendars.ReadWrite"
      }

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :needs_refresh} end)

      expect(TeamsOAuthHelperMock, :refresh_access_token, fn "refresh", _scope ->
        {:ok,
         %{
           access_token: "new_token",
           refresh_token: "new_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600),
           scope: "Calendars.ReadWrite"
         }}
      end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and v == "Bearer new_token"
               end)

        {:ok,
         %Req.Response{
           status: 201,
           body: Jason.encode!(%{"id" => "m1", "onlineMeetingUrl" => "url"})
         }}
      end)

      assert {:ok, _result} = TeamsProvider.create_meeting_room(config)

      # Verify DB update
      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_token"
    end

    test "refresh path without integration_id/user_id bypasses persistence" do
      config = %{
        access_token: "expired",
        refresh_token: "refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        oauth_scope: "Calendars.ReadWrite"
      }

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :needs_refresh} end)

      expect(TeamsOAuthHelperMock, :refresh_access_token, fn "refresh", _scope ->
        {:ok,
         %{
           access_token: "fresh_token",
           refresh_token: "fresh_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
           scope: "Calendars.ReadWrite"
         }}
      end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and v == "Bearer fresh_token"
               end)

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => "m3",
               "onlineMeetingUrl" => "https://teams.microsoft.com/l/meetup-join/no-ids"
             })
         }}
      end)

      assert {:ok, room} = TeamsProvider.create_meeting_room(config)
      assert room.room_id == "m3"
    end

    test "skips refresh and uses fresh DB token when token already refreshed concurrently" do
      user = insert(:user)
      fresh_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Teams",
          provider: "teams",
          tenant_id: "tenant1",
          teams_user_id: "teams-user-1",
          access_token: "fresh-token-from-other-process",
          refresh_token: "fresh-refresh",
          token_expires_at: fresh_expiry,
          oauth_scope: "Calendars.ReadWrite"
        })

      config = %{
        access_token: "stale-token-current-process",
        refresh_token: "ref",
        token_expires_at: DateTime.add(DateTime.utc_now(), -10, :second),
        oauth_scope: "Calendars.ReadWrite",
        integration_id: integration.id,
        user_id: user.id
      }

      # Current process thinks the token needs refreshing; after acquiring the
      # lock the DB re-fetch reveals a fresh token — no OAuth call should fire.
      stub(TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :needs_refresh} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and
                   v == "Bearer fresh-token-from-other-process"
               end)

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => "m4",
               "onlineMeetingUrl" => "https://teams.microsoft.com/l/meetup-join/concurrent"
             })
         }}
      end)

      assert {:ok, _room} = TeamsProvider.create_meeting_room(config)
    end

    test "flags the integration as needs_reauth on a 401 from Graph" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Teams",
          provider: "teams",
          tenant_id: "t1",
          teams_user_id: "u1",
          access_token: "valid_token",
          refresh_token: "refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "Calendars.ReadWrite"
        })

      config = %{
        access_token: "valid_token",
        refresh_token: "refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        integration_id: integration.id,
        user_id: user.id,
        oauth_scope: "Calendars.ReadWrite"
      }

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"error" => %{"code" => "InvalidAuthenticationToken"}})
         }}
      end)

      assert {:error, _message} = TeamsProvider.create_meeting_room(config)

      flagged = Repo.get(VideoIntegrationSchema, integration.id)
      assert flagged.needs_reauth == true
      assert flagged.sync_error =~ "reconnect"
    end

    test "does not crash on a 401 when integration_id/user_id are absent" do
      config = valid_config()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: Jason.encode!(%{"error" => %{"code" => "X"}})}}
      end)

      assert {:error, _message} = TeamsProvider.create_meeting_room(config)
    end

    test "returns error when API response is malformed JSON" do
      config = valid_config()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 201, body: "not valid json{{"}}
      end)

      assert {:error, _reason} = TeamsProvider.create_meeting_room(config)
    end

    test "handles malformed or missing fields in Graph API response" do
      config = valid_config()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      # Missing joinUrl
      expect(HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %Req.Response{status: 201, body: Jason.encode!(%{"id" => "m1"})}}
      end)

      assert {:error, message} = TeamsProvider.create_meeting_room(config)
      assert String.contains?(message, "Teams meeting link was not generated")

      # Audio conferencing missing
      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok,
         %Req.Response{
           status: 201,
           body: Jason.encode!(%{"id" => "m2", "onlineMeetingUrl" => "url2"})
         }}
      end)

      assert {:ok, room_data} = TeamsProvider.create_meeting_room(config)
      assert room_data.provider_data.toll_number == nil
      assert room_data.provider_data.conference_id == nil
    end
  end

  describe "create_join_url/5" do
    test "creates join URL with participant display name" do
      room_data = %{
        meeting_url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123%40thread.v2/0"
      }

      participant_name = "John Doe"
      participant_email = "john@example.com"
      role = "attendee"
      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               TeamsProvider.create_join_url(
                 room_data,
                 participant_name,
                 participant_email,
                 role,
                 meeting_time
               )

      assert String.contains?(join_url, "displayName=John")
      assert String.contains?(join_url, "Doe")
    end
  end

  describe "extract_room_id/1" do
    test "extracts room ID from Teams meeting URL" do
      meeting_url =
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abcdefgh123456%40thread.v2/0"

      room_id = TeamsProvider.extract_room_id(meeting_url)

      # The extractor caps the encoded join id at 20 characters.
      assert room_id == "19%3ameeting_abcdefg"
    end

    test "returns nil for non-string input" do
      # The callback contract only accepts meeting URLs; map unwrapping for
      # meeting-context shapes happens once, upstream, in Video.Urls.
      assert TeamsProvider.extract_room_id(%{room_data: %{room_id: "abc"}}) == nil
      assert TeamsProvider.extract_room_id(%{}) == nil
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts valid Teams meeting URL" do
      url = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123%40thread.v2/0"

      assert TeamsProvider.valid_meeting_url?(url)
    end
  end

  describe "handle_meeting_event/3" do
    test "returns :ok for meeting_ended event" do
      room_data = %{room_id: "meeting123"}

      assert TeamsProvider.handle_meeting_event(:meeting_ended, room_data, %{}) == :ok
    end
  end

  describe "generate_meeting_metadata/1" do
    test "returns metadata with Teams-specific features" do
      room_data = %{
        room_id: "meeting123",
        meeting_url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0",
        provider_data: %{
          "passcode" => "123456",
          "toll_number" => "+1-555-0100",
          "conference_id" => "987654321"
        }
      }

      metadata = TeamsProvider.generate_meeting_metadata(room_data)

      assert metadata[:provider] == "teams"
      assert metadata[:meeting_id] == "meeting123"
      assert metadata[:passcode] == "123456"
    end
  end

  defp valid_config do
    %{
      access_token: "valid_token",
      refresh_token: "refresh_token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "Calendars.ReadWrite"
    }
  end
end
