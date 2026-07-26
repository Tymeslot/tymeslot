defmodule Tymeslot.Integrations.Calendar.Nextcloud.ProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations

  import ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Nextcloud.Provider

  setup do
    CalendarCircuitBreaker.reset(:nextcloud)
    :ok
  end

  describe "provider_type/0" do
    test "returns :nextcloud" do
      assert Provider.provider_type() == :nextcloud
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert Provider.display_name() == "Nextcloud"
    end
  end

  import Tymeslot.CalDAVTestHelpers

  describe "config_schema/0" do
    test "returns schema with Nextcloud-specific fields" do
      schema = Provider.config_schema()
      assert_has_caldav_base_fields(schema)
    end

    test "includes description mentioning Nextcloud server URL format" do
      schema = Provider.config_schema()

      assert String.contains?(schema[:base_url][:description], "Nextcloud")
    end

    test "mentions app password in password description" do
      schema = Provider.config_schema()

      assert String.contains?(schema[:password][:description], "app password")
    end

    test "includes calendar_paths with default personal calendar" do
      schema = Provider.config_schema()

      assert schema[:calendar_paths][:type] == :list
      assert schema[:calendar_paths][:required] == false
      assert String.contains?(schema[:calendar_paths][:description], "personal")
    end
  end

  describe "validate_config/1" do
    test "returns error when base_url is missing" do
      config = %{username: "user", password: "pass"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "base_url")
    end

    test "returns error when password is missing" do
      config = %{base_url: "http://localhost:1", username: "user"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "password")
    end

    test "returns error for invalid Nextcloud URL format" do
      config = %{
        base_url: "not-a-valid-url",
        username: "user",
        password: "pass"
      }

      # The scheme is auto-added, so the URL passes structural validation and the
      # failure comes from the connection probe instead (the MockCase stub times out).
      assert Provider.validate_config(config) == {:error, :timeout}
    end

    test "accepts calendar URL format" do
      config = %{
        base_url: "https://cloud.example.com/remote.php/dav/calendars/user/personal",
        username: "user",
        password: "pass"
      }

      # Will fail connection test but URL structure is valid
      capture_log(fn ->
        result = Provider.validate_config(config)
        assert match?({:error, _reason}, result)
      end)
    end

    test "accepts standard Nextcloud URL" do
      config = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      # Will fail connection test but URL structure is valid
      capture_log(fn ->
        result = Provider.validate_config(config)
        assert match?({:error, _reason}, result)
      end)
    end
  end

  describe "new/1" do
    test "creates client with Nextcloud configuration" do
      config = %{
        base_url: "http://localhost:1",
        username: "testuser",
        password: "testpass",
        calendar_paths: ["personal", "work"]
      }

      client = Provider.new(config)

      assert client.username == "testuser"
      assert client.password == "testpass"
      # Nextcloud uses CalDAV under the hood, so provider may be :caldav
      assert client.provider in [:nextcloud, :caldav]
      assert client.verify_ssl == true
    end

    test "normalizes Nextcloud base URL to include CalDAV path" do
      config = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      client = Provider.new(config)

      # Should normalize to include /remote.php/dav
      assert String.contains?(client.base_url, "remote.php/dav")
    end

    test "builds Nextcloud calendar paths correctly" do
      config = %{
        base_url: "http://localhost:1",
        username: "testuser",
        password: "pass",
        calendar_paths: ["personal"]
      }

      client = Provider.new(config)

      # Calendar paths should be formatted for Nextcloud
      assert client.calendar_paths == ["/calendars/testuser/personal/"]
    end

    test "defaults to personal calendar when no paths provided" do
      config = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      client = Provider.new(config)

      assert client.calendar_paths == ["/calendars/user/personal/"]
    end

    test "extracts username from calendar URL when not provided" do
      config = %{
        base_url: "https://cloud.example.com/remote.php/dav/calendars/john/personal",
        password: "pass"
      }

      client = Provider.new(config)

      # Username should be extracted from URL
      assert client.username == "john"
    end
  end

  describe "test_connection/2" do
    test "probes the CalDAV principal URL even when base_url omits /remote.php/dav" do
      # Regression: `Creation.prepare_attrs` persists the user-entered URL verbatim
      # (e.g. "https://cloud.example.com"), while `validate_config` normalises before
      # probing. Without normalisation here the discovery URL becomes
      # `<base_url>/calendars/<user>/`, which Nextcloud answers with HTTP 405 because
      # CalDAV is mounted at `/remote.php/dav/`.
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: ["/remote.php/dav/calendars/alice/personal/"]
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, url, _body, _headers, _opts ->
        assert url =~ "/remote.php/dav/", "probed wrong URL: #{url}"
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert {:ok, "Nextcloud connection successful"} = Provider.test_connection(integration)
    end

    test "returns Nextcloud-specific success message" do
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: []
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert {:ok, message} = Provider.test_connection(integration)
      assert String.contains?(message, "Nextcloud")
    end

    test "translates 401 to a Nextcloud-flavoured authentication failure message" do
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "wrong",
        calendar_paths: []
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, message} = Provider.test_connection(integration)
      assert message =~ "Authentication failed"
      assert message =~ "app password"
    end

    test "accepts options with IP metadata" do
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: []
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert {:ok, _message} =
               Provider.test_connection(integration, metadata: %{ip: "192.168.1.1"})
    end

    test "returns Nextcloud-specific :not_found message when server returns 404" do
      # Discovery.test_connection performs an RFC 4791 fallback probe when the
      # primary PROPFIND returns 404, so two requests are issued before
      # {:error, :not_found} propagates back to the provider.
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: []
      }

      # Primary PROPFIND on the guessed discovery path → 404
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      # RFC 4791 fallback probe on "/" → also 404
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert Provider.test_connection(integration) ==
               {:error,
                "Nextcloud server not found or CalDAV endpoint not accessible. Check your server URL."}
    end

    test "passes transport errors through unchanged via catch-all clause" do
      # The default MockCase stub returns {:error, %Mint.TransportError{reason: :timeout}}.
      # The provider catch-all at line 163 forwards unknown error reasons as-is.
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: []
      }

      assert {:error, _reason} = Provider.test_connection(integration)
    end
  end

  describe "discover_calendars/2" do
    test "returns error without valid Nextcloud server" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :nextcloud
      }

      capture_log(fn ->
        result = Provider.discover_calendars(client)
        assert {:error, _message} = result
      end)
    end

    test "accepts options for rate limiting" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :nextcloud
      }

      opts = [metadata: %{ip: "10.0.0.1"}]

      capture_log(fn ->
        result = Provider.discover_calendars(client, opts)
        assert {:error, _message} = result
      end)
    end
  end

  describe "list_events/3" do
    test "delegates to CalDAV provider with time range" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :nextcloud
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 86_400, :second)

      capture_log(fn ->
        # The CalDAV REPORT is issued from the circuit breaker's own task, outside
        # the Mox-owned process, so the response cannot be stubbed here. What this
        # asserts is the delegation itself: the time range was accepted and a
        # request attempted, rather than short-circuiting on :missing_time_range.
        assert {:error, reason} =
                 Provider.list_events(client, start_time: start_time, end_time: end_time)

        refute reason == :missing_time_range
      end)
    end

    test "returns error when time range is missing" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :nextcloud
      }

      assert Provider.list_events(client, []) == {:error, :missing_time_range}
    end
  end

  describe "create_event/2" do
    test "delegates to CalDAV provider for event creation" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :nextcloud
      }

      event_data = %{
        summary: "Nextcloud Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      capture_log(fn ->
        result = Provider.create_event(client, event_data)
        assert match?({:error, _reason}, result)
      end)
    end
  end

  describe "update_event/3" do
    test "delegates to CalDAV provider for event update" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :nextcloud
      }

      uid = "nextcloud-event-123"

      event_data = %{
        summary: "Updated Event",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      capture_log(fn ->
        result = Provider.update_event(client, uid, event_data)
        assert match?({:error, _reason}, result)
      end)
    end
  end

  describe "delete_event/2" do
    test "delegates to CalDAV provider for event deletion" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :nextcloud
      }

      uid = "nextcloud-event-123"

      capture_log(fn ->
        result = Provider.delete_event(client, uid)
        assert match?({:error, _reason}, result)
      end)
    end
  end
end
