defmodule Tymeslot.Integrations.Video.Providers.GoogleMeetProviderTest do
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

  describe "config_schema/0" do
    test "returns schema with required OAuth fields" do
      schema = GoogleMeetProvider.config_schema()

      assert schema[:access_token][:type] == :string
      assert schema[:access_token][:required] == true
      assert schema[:refresh_token][:type] == :string
      assert schema[:refresh_token][:required] == true
      assert schema[:token_expires_at][:type] == :datetime
      assert schema[:token_expires_at][:required] == true
    end
  end

  describe "validate_config/1" do
    test "returns error when access_token is missing" do
      config = %{
        refresh_token: "refresh_token",
        token_expires_at: DateTime.utc_now()
      }

      assert {:error, message} = GoogleMeetProvider.validate_config(config)
      assert String.contains?(message, "access_token")
    end

    test "returns error when refresh_token is missing" do
      config = %{
        access_token: "access_token",
        token_expires_at: DateTime.utc_now()
      }

      assert {:error, message} = GoogleMeetProvider.validate_config(config)
      assert String.contains?(message, "refresh_token")
    end

    test "returns error when token_expires_at is missing" do
      config = %{
        access_token: "access_token",
        refresh_token: "refresh_token"
      }

      assert {:error, message} = GoogleMeetProvider.validate_config(config)
      assert String.contains?(message, "token_expires_at")
    end

    test "returns :ok when all required fields present" do
      config = %{
        access_token: "access_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.utc_now()
      }

      assert :ok = GoogleMeetProvider.validate_config(config)
    end
  end

  describe "test_connection/1" do
    test "returns success when API calls succeed" do
      config = %{
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"items" => []})}}
      end)

      assert {:ok, message} = GoogleMeetProvider.perform_connection_test(config)
      assert String.contains?(message, "successful")
    end

    test "returns error when API call fails" do
      config = %{
        access_token: "invalid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: "Unauthorized"}}
      end)

      assert {:error, message} = GoogleMeetProvider.perform_connection_test(config)
      assert String.contains?(message, "Connection test failed")
    end

    test "returns error when API returns malformed JSON in connection test" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "not json"}}
      end)

      assert {:error, message} = GoogleMeetProvider.perform_connection_test(config)
      assert message =~ "Invalid JSON"
    end

    test "refreshes token if expired during connection test" do
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      new_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      config = %{
        access_token: "expired_token",
        refresh_token: "refresh_token",
        token_expires_at: expires_at,
        oauth_scope: "scope"
      }

      expect(GoogleOAuthHelperMock, :refresh_access_token, fn "refresh_token", "scope", _opts ->
        {:ok,
         %{
           access_token: "new_token",
           refresh_token: "new_refresh_token",
           expires_at: new_expires_at,
           scope: "scope"
         }}
      end)

      expect(HTTPClientMock, :request, fn :get, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer new_token"} in headers
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"items" => []})}}
      end)

      assert {:ok, _result} = GoogleMeetProvider.perform_connection_test(config)
    end
  end

  describe "create_join_url/5" do
    # Meet has no per-person join link, and `authuser=<email>` sends anyone not
    # signed in under that exact address to a Google sign-in page instead of
    # the room, so both roles must get the untouched meeting URL.
    for role <- ["organizer", "participant"] do
      test "returns the plain meeting URL for the #{role} role" do
        room_data = %{meeting_url: "https://meet.google.com/abc-defg-hij"}

        assert GoogleMeetProvider.create_join_url(
                 room_data,
                 "John Doe",
                 "john@example.com",
                 unquote(role),
                 DateTime.utc_now()
               ) == {:ok, "https://meet.google.com/abc-defg-hij"}
      end
    end

    test "returns error when meeting_url is missing" do
      room_data = %{room_id: "abc-defg-hij", meeting_url: nil}
      meeting_time = DateTime.utc_now()

      assert {:error, message} =
               GoogleMeetProvider.create_join_url(
                 room_data,
                 "User",
                 "user@example.com",
                 "attendee",
                 meeting_time
               )

      assert String.contains?(message, "Missing meeting URL")
    end
  end

  describe "extract_room_id/1" do
    test "extracts room ID from valid Google Meet URL" do
      meeting_url = "https://meet.google.com/abc-defg-hij"

      assert GoogleMeetProvider.extract_room_id(meeting_url) == "abc-defg-hij"
    end

    test "handles URL with query parameters" do
      meeting_url = "https://meet.google.com/xyz-abcd-efg?authuser=user@example.com"

      assert GoogleMeetProvider.extract_room_id(meeting_url) == "xyz-abcd-efg"
    end

    test "returns nil for non-Google Meet URL" do
      assert GoogleMeetProvider.extract_room_id("https://example.com/meeting/123456") == nil
    end

    test "returns nil for malformed Google Meet URL" do
      assert GoogleMeetProvider.extract_room_id("https://meet.google.com/") == nil
    end

    test "extracts path segment even for non-standard format" do
      # The function extracts the path segment without validating format
      assert GoogleMeetProvider.extract_room_id("https://meet.google.com/invalid") == "invalid"
    end

    test "handles nil input" do
      assert GoogleMeetProvider.extract_room_id(nil) == nil
    end

    test "handles empty string" do
      assert GoogleMeetProvider.extract_room_id("") == nil
    end
  end

  describe "create_meeting_room/1 reauth flagging" do
    test "flags the integration as needs_reauth on a 401 from the Meet API" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Google Meet",
          provider: "google_meet",
          access_token: "valid_token",
          refresh_token: "refresh_token",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "https://www.googleapis.com/auth/calendar"
        })

      config = %{
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        integration_id: integration.id,
        user_id: user.id,
        oauth_scope: "https://www.googleapis.com/auth/calendar"
      }

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: "Unauthorized"}}
      end)

      assert {:error, _message} = GoogleMeetProvider.create_meeting_room(config)

      flagged = Repo.get(VideoIntegrationSchema, integration.id)
      assert flagged.needs_reauth == true
      assert flagged.sync_error =~ "reconnect"
    end

    test "does not crash on a 401 when integration_id/user_id are absent" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: "Unauthorized"}}
      end)

      assert {:error, _message} = GoogleMeetProvider.create_meeting_room(config)
    end
  end

  defp valid_token_config do
    %{
      access_token: "valid_token",
      refresh_token: "refresh_token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end
end
