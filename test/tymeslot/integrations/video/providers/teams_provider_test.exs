defmodule Tymeslot.Integrations.Video.Providers.TeamsProviderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
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

      assert capabilities[:supports_instant_meetings] == false
      assert capabilities[:supports_scheduled_meetings] == true
      assert capabilities[:supports_recurring_meetings] == false
      assert capabilities[:supports_waiting_room] == true
      assert capabilities[:supports_recording] == true
      assert capabilities[:supports_dial_in] == true
      assert capabilities[:max_participants] == 300
      assert capabilities[:requires_account] == true
      assert capabilities[:supports_custom_branding] == false
      assert capabilities[:supports_breakout_rooms] == true
      assert capabilities[:supports_screen_sharing] == true
      assert capabilities[:supports_chat] == true
      assert capabilities[:requires_work_account] == true
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

    test "returns error when API response is malformed JSON" do
      config = %{
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "Calendars.ReadWrite"
      }

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 201, body: "not valid json{{"}}
      end)

      assert {:error, _reason} = TeamsProvider.create_meeting_room(config)
    end

    test "handles malformed or missing fields in Graph API response" do
      config = %{
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "Calendars.ReadWrite"
      }

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

      assert is_binary(room_id)
      assert String.length(room_id) == 20
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
end
