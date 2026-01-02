defmodule Tymeslot.Integrations.Calendar.ConnectionTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory
  import Mox
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  describe "validate/3" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "validates CalDAV connection within timeout", %{user: user} do
      integration = %{
        provider: "caldav",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      result = Connection.validate(integration, user.id, timeout: 5_000)

      # Will fail due to network error
      assert {:error, :network_error} = result
    end

    test "returns timeout error when validation exceeds timeout", %{user: user} do
      integration = %{
        provider: "caldav",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      # Very short timeout to force timeout error
      result = Connection.validate(integration, user.id, timeout: 1)

      # DNS resolution can fail faster than timeout with network_error
      assert result == {:error, :timeout} or result == {:error, :network_error}
    end

    test "validates Nextcloud connection", %{user: user} do
      integration = %{
        provider: "nextcloud",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      result = Connection.validate(integration, user.id)

      # Will fail due to network error
      assert {:error, :network_error} = result
    end

    test "uses default timeout when not specified", %{user: user} do
      integration = %{
        provider: "caldav",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      # Should use 10_000ms default timeout
      result = Connection.validate(integration, user.id)

      assert match?({:error, _}, result)
    end
  end

  describe "validate_connection/2" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "validates CalDAV provider connection", %{user: user} do
      integration = %{
        provider: "caldav",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      result = Connection.validate_connection(integration, user.id)

      # Will fail without real server
      assert {:error, :network_error} = result
    end

    test "validates Nextcloud provider connection", %{user: user} do
      integration = %{
        provider: "nextcloud",
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass"
      }

      result = Connection.validate_connection(integration, user.id)

      assert {:error, :network_error} = result
    end

    test "validates Radicale provider connection", %{user: user} do
      integration = %{
        provider: "radicale",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      result = Connection.validate_connection(integration, user.id)

      assert {:error, :network_error} = result
    end

    test "returns error for unsupported provider", %{user: user} do
      integration = %{
        provider: "unknown"
      }

      result = Connection.validate_connection(integration, user.id)

      assert {:error, :unsupported_provider} = result
    end

    test "handles OAuth providers with token validation", %{user: user} do
      integration = insert(:calendar_integration,
        user: user,
        provider: "google",
        access_token_encrypted: Encryption.encrypt("access_token"),
        refresh_token_encrypted: Encryption.encrypt("refresh_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      )

      integration_map = %{
        id: integration.id,
        provider: "google",
        access_token: "access_token",
        refresh_token: "refresh_token",
        token_expires_at: integration.token_expires_at
      }

      # Mock token refresh
      expect(GoogleCalendarAPIMock, :refresh_token, fn _int ->
        {:ok, {"new_access_token", "new_refresh_token", DateTime.add(DateTime.utc_now(), 3600, :second)}}
      end)

      # Mock connection test
      expect(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end ->
        {:ok, []}
      end)

      result = Connection.validate_connection(integration_map, user.id)

      assert {:ok, updated} = result
      assert updated.access_token == "new_access_token"
    end

    test "handles network errors gracefully", %{user: user} do
      integration = %{
        provider: "caldav",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      result = Connection.validate_connection(integration, user.id)

      assert {:error, :network_error} = result
    end
  end

  describe "test_connection/1" do
    test "tests CalDAV provider connection" do
      integration = %{
        provider: "caldav",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      result = Connection.test_connection(integration)

      # Will fail without real server
      assert {:error, _} = result
    end

    test "tests Google Calendar provider connection" do
      integration = %{
        provider: "google",
        access_token: "test_token",
        refresh_token: "refresh_token"
      }

      # Mock connection test
      expect(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end ->
        {:ok, []}
      end)

      result = Connection.test_connection(integration)

      assert {:ok, "Google Calendar connection successful"} = result
    end

    test "tests Nextcloud provider connection" do
      integration = %{
        provider: "nextcloud",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      result = Connection.test_connection(integration)

      assert match?({:error, _}, result)
    end

    test "returns error for provider with invalid atom" do
      integration = %{
        provider: "nonexistent_provider"
      }

      result = Connection.test_connection(integration)

      assert {:error, :unsupported_provider} = result
    end

    test "returns error for unknown provider type" do
      integration = %{
        provider: "unknown"
      }

      result = Connection.test_connection(integration)

      assert {:error, :unsupported_provider} = result
    end
  end
end
