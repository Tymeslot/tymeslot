defmodule Tymeslot.Integrations.Calendar.CalDAV.ProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations
  import ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalDAV.Provider

  setup :verify_on_exit!

  setup do
    CalendarCircuitBreaker.reset(:caldav)
    :ok
  end

  describe "provider_type/0" do
    test "returns :caldav" do
      assert Provider.provider_type() == :caldav
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert Provider.display_name() == "CalDAV"
    end
  end

  import Tymeslot.CalDAVTestHelpers

  describe "config_schema/0" do
    test "returns schema with required CalDAV fields" do
      schema = Provider.config_schema()
      assert_has_caldav_base_fields(schema)
    end

    test "includes optional calendar_paths field" do
      schema = Provider.config_schema()

      assert schema[:calendar_paths][:type] == :list
      assert schema[:calendar_paths][:required] == false
    end
  end

  describe "validate_config/1" do
    import Tymeslot.CalendarProviderValidationCases

    test "validates basic required fields" do
      assert test_basic_validation(Provider, "https://caldav.example.com") == :ok
    end

    test "accepts a complete config without touching the network" do
      assert test_validation_accepts_without_network_probe(
               Provider,
               "https://caldav.example.com"
             ) == :ok
    end
  end

  describe "new/1" do
    test "creates client with generic CalDAV configuration" do
      config = %{
        base_url: "https://caldav.example.com/dav",
        username: "testuser",
        password: "testpass",
        calendar_paths: ["/calendars/testuser/personal/"]
      }

      client = Provider.new(config)

      assert client.username == "testuser"
      assert client.password == "testpass"
      assert client.verify_ssl == true
      # Generic CalDAV URL should remain :caldav
      assert client.provider == :caldav
    end

    test "auto-detects Radicale from URL with 'radicale' in hostname" do
      config = %{
        base_url: "https://radicale.example.com",
        username: "testuser",
        password: "testpass"
      }

      client = Provider.new(config)

      assert client.provider == :radicale
    end

    test "auto-detects Radicale from port 5232" do
      config = %{
        base_url: "https://cal.example.com:5232",
        username: "testuser",
        password: "testpass"
      }

      client = Provider.new(config)

      assert client.provider == :radicale
    end

    test "auto-detects Nextcloud from URL with 'nextcloud' in hostname" do
      config = %{
        base_url: "https://nextcloud.example.com",
        username: "testuser",
        password: "testpass"
      }

      client = Provider.new(config)

      assert client.provider == :nextcloud
    end

    test "auto-detects Nextcloud from remote.php/dav path" do
      config = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "testuser",
        password: "testpass"
      }

      client = Provider.new(config)

      assert client.provider == :nextcloud
    end

    test "auto-detects ownCloud from URL" do
      config = %{
        base_url: "https://owncloud.example.com",
        username: "testuser",
        password: "testpass"
      }

      client = Provider.new(config)

      assert client.provider == :owncloud
    end

    test "auto-detects Baikal from URL with 'baikal' in hostname" do
      config = %{
        base_url: "https://baikal.example.com",
        username: "testuser",
        password: "testpass"
      }

      client = Provider.new(config)

      assert client.provider == :baikal
    end

    test "auto-detects Baikal legacy from cal.php path" do
      config = %{
        base_url: "https://example.com/cal.php",
        username: "testuser",
        password: "testpass"
      }

      client = Provider.new(config)

      assert client.provider == :baikal_legacy
    end

    test "auto-detects SabreDAV from URL" do
      config = %{
        base_url: "https://sabredav.example.com",
        username: "testuser",
        password: "testpass"
      }

      client = Provider.new(config)

      assert client.provider == :sabredav
    end

    test "normalizes base URL" do
      config = %{
        base_url: "https://caldav.example.com/dav/",
        username: "user",
        password: "pass"
      }

      client = Provider.new(config)

      # URL should be normalized (trailing slash removed)
      assert client.base_url == "https://caldav.example.com/dav"
    end

    test "sets empty calendar_paths when not provided" do
      config = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass"
      }

      client = Provider.new(config)

      assert client.calendar_paths == []
    end
  end

  describe "list_events/3" do
    test "delegates a valid time range to CaldavCommon" do
      # Nothing is sent: `CaldavCommon.get_events/3` refuses a client with no
      # configured calendar path before any request is built. That refusal is
      # the proof the range was accepted and the call reached the shared
      # module, rather than short-circuiting on :missing_time_range here.
      client = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :caldav
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      assert Provider.list_events(client, start_time: start_time, end_time: end_time) ==
               {:error, "No calendars configured"}
    end

    test "returns error when time range is missing" do
      client = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      assert Provider.list_events(client, []) == {:error, :missing_time_range}
    end
  end

  describe "create_event/2" do
    test "delegates to CaldavCommon, which refuses without a target calendar" do
      # The message is CaldavCommon's own and is returned before any request
      # is built, so it pins the delegation without needing a live server.
      client = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :caldav
      }

      event_data = %{
        summary: "Test Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Provider.create_event(client, event_data) ==
               {:error, "No calendar configured for creating events"}
    end
  end

  describe "update_event/3" do
    test "delegates to CaldavCommon, which reports an unconfigured calendar as not found" do
      client = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :caldav
      }

      event_data = %{
        summary: "Updated Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Provider.update_event(client, "test-event-123", event_data) ==
               {:error, "Event not found"}
    end
  end

  describe "delete_event/2" do
    test "delegates to CaldavCommon, for which deleting from no calendar is a no-op" do
      # Deletion is idempotent by design: with nothing configured there is
      # nothing to remove, so CaldavCommon reports success rather than an
      # error. Asserting `:ok` pins that contract; the previous
      # `{:error, _}` assertion described the opposite behaviour.
      client = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :caldav
      }

      assert Provider.delete_event(client, "test-event-123") == :ok
    end
  end

  describe "test_connection/1" do
    test "refuses a loopback base_url before any request is issued" do
      # `CalDAV.Discovery` validates the URL with `block_private_ips: true`
      # unless `:allow_private_ips_for_calendar` is set, so the probe never
      # reaches a socket. Pinning the guard's own message is what proves the
      # guard fired, rather than the connection merely having failed.
      integration = %{
        base_url: "http://localhost:1",
        username: "invalid",
        password: "wrong",
        calendar_paths: []
      }

      assert Provider.perform_connection_test(integration) ==
               {:error, "Private or local network addresses are not allowed"}
    end

    test "is pure I/O — takes only the integration, no caller options" do
      integration = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert Provider.perform_connection_test(integration) ==
               {:ok, "CalDAV connection successful"}
    end

    test "probes the stored calendar path rather than re-guessing a discovery URL" do
      # A server whose calendar collection does not live where the naming
      # heuristic guesses, and whose origin root refuses PROPFIND (405): the
      # full discovery chain dead-ends on both, while the path the sync worker
      # actually uses answers fine. Re-guessing here is what made the periodic
      # health check report a syncing calendar as unreachable.
      integration = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: ["/dav/user/personal/"]
      }

      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :request, fn :propfind, url, _body, _headers, _opts ->
        send(test_pid, {:propfind, url})

        if String.contains?(url, "/dav/user/personal/") do
          {:ok, %Req.Response{status: 207, body: ""}}
        else
          {:ok, %Req.Response{status: 405, body: ""}}
        end
      end)

      assert Provider.perform_connection_test(integration) ==
               {:ok, "CalDAV connection successful"}

      assert_received {:propfind, "https://caldav.example.com/dav/user/personal/"}
      refute_received {:propfind, _other_url}
    end

    test "still reports a genuine failure against the stored calendar path" do
      # The stored path is not a free pass: revoked credentials on the very
      # collection the sync worker reads must still fail the check.
      integration = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "stale",
        calendar_paths: ["/dav/user/personal/"]
      }

      stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert Provider.perform_connection_test(integration) == {:error, :unauthorized}
    end

    test "falls back to full discovery when no calendar path has been stored yet" do
      # Onboarding: nothing is discovered yet, so the guessed URL is all there
      # is to probe. `check_connectivity/1` would probe `/` here, which is
      # exactly the request some servers refuse.
      integration = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :request, fn :propfind, url, _body, _headers, _opts ->
        send(test_pid, {:propfind, url})
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert Provider.perform_connection_test(integration) ==
               {:ok, "CalDAV connection successful"}

      assert_received {:propfind, "https://caldav.example.com/calendars/user/"}
    end
  end

  describe "discover_calendars/1" do
    test "returns error without valid server" do
      client = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :caldav
      }

      capture_log(fn ->
        result = Provider.discover_calendars(client)
        assert {:error, _message} = result
      end)
    end
  end
end
