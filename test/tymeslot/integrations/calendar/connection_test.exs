defmodule Tymeslot.Integrations.Calendar.ConnectionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Nextcloud.Provider, as: NextcloudProvider
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  describe "validate/3" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "surfaces the CalDAV connection failure when it lands inside the timeout", %{user: user} do
      integration = %{
        provider: "caldav",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      # Nothing listens on port 1, so the connection is refused immediately and
      # the task finishes well inside the 5s budget: the timeout branch is not
      # in play, the underlying failure is what must come back.
      assert Connection.validate(integration, user.id, timeout: 5_000) ==
               {:error, :network_error}
    end

    test "returns timeout error when validation exceeds timeout", %{user: user} do
      # A CalDAV target cannot produce this branch: an unreachable host is
      # refused far faster than any timeout, and SSRF protection rejects a
      # local stub server before a byte is sent. The mocked Google boundary is
      # the one call this module makes that can be told to hang, so that is
      # what the timeout is measured against.
      integration = %{
        id: 1,
        user_id: user.id,
        provider: "google",
        access_token: "access_token",
        refresh_token: "refresh_token",
        # Still valid, so the token-refresh call is not part of this test.
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      stub(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end ->
        # Never returns; the task is shut down when the budget is exceeded.
        Process.sleep(:infinity)
      end)

      assert Connection.validate(integration, user.id, timeout: 100) == {:error, :timeout}
    end

    test "collapses a Nextcloud discovery refusal to :network_error", %{user: user} do
      integration = %{
        provider: "nextcloud",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      # Two halves, because `validate_connection/2` maps every discovery error
      # onto the same atom and so cannot tell them apart on its own. The first
      # assertion names the actual cause — the SSRF guard refuses the loopback
      # URL before a socket opens — and the second pins the collapse: none of
      # that wording is allowed to reach the caller.
      assert NextcloudProvider.discover_calendars(Map.put(integration, :calendar_paths, [])) ==
               {:error, "Private or local network addresses are not allowed"}

      assert Connection.validate(integration, user.id) == {:error, :network_error}
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

      assert match?({:error, _reason}, result)
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
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("access_token"),
          refresh_token_encrypted: Encryption.encrypt("refresh_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          oauth_scope: "https://www.googleapis.com/auth/calendar"
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
        {:ok,
         {"new_access_token", "new_refresh_token",
          DateTime.add(DateTime.utc_now(), 3600, :second)}}
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
      assert {:error, _reason} = result
    end

    test "tests Google Calendar provider connection" do
      user = insert(:user)

      integration = %{
        provider: "google",
        access_token: "test_token",
        refresh_token: "refresh_token",
        user_id: user.id
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

      assert match?({:error, _reason}, result)
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
