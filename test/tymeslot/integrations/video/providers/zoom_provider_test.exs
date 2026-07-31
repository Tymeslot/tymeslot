defmodule Tymeslot.Integrations.Video.Providers.ZoomProviderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Video.Providers.ZoomProvider
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

      assert capabilities[:waiting_room] == true
      assert capabilities[:max_participants] == 100
      assert capabilities[:recording] == true
      assert capabilities[:dial_in] == true
      assert capabilities[:breakout_rooms] == true
      assert capabilities[:screen_sharing] == true
      assert capabilities[:chat] == true
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

      assert {:ok, message} = ZoomProvider.perform_connection_test(config)
      assert String.contains?(message, "connected successfully")
    end

    test "returns error when token validation fails" do
      config = %{access_token: "bad"}

      expect(ZoomOAuthHelperMock, :validate_token, fn _config -> {:error, "expired"} end)

      assert {:error, message} = ZoomProvider.perform_connection_test(config)
      assert String.contains?(message, "Failed to authenticate")
      assert String.contains?(message, "expired")
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

    test "form-encodes the participant name so it cannot inject query params" do
      room_data = %{meeting_url: "https://zoom.us/j/123456789"}

      assert {:ok, url} =
               ZoomProvider.create_join_url(room_data, "x&pwd=1234", "x@x", "attendee", nil)

      # The malicious '&pwd=1234' must be percent-encoded into the uname value,
      # never surface as a separate query parameter.
      refute String.contains?(url, "&pwd=1234")
      assert String.contains?(url, "uname=x%26pwd%3D1234")
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

    test "returns nil for non-string input" do
      # The callback contract only accepts meeting URLs; map unwrapping for
      # meeting-context shapes happens once, upstream, in Video.Urls.
      assert ZoomProvider.extract_room_id(%{room_data: %{room_id: "abc"}}) == nil
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
      oauth_scope: "meeting:write:meeting meeting:read:meeting user:read:user",
      meeting_topic: "Test Meeting",
      meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
      meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
    }
  end
end
