defmodule Tymeslot.Integrations.Calendar.CalDAV.ProviderTest do
  use ExUnit.Case, async: true

  import Mox
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
      test_basic_validation(Provider, "https://caldav.example.com")
    end

    test "attempts connection when all required fields present" do
      test_validation_attempts_connection(Provider, "https://caldav.example.com")
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
      assert is_binary(client.base_url)
      assert String.contains?(client.base_url, "caldav.example.com")
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

  describe "get_events/1" do
    test "delegates to CaldavCommon" do
      client = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      # Should fail immediately with econnrefused or similar, not time out
      capture_log(fn ->
        result = Provider.get_events(client)
        assert match?({:error, _}, result) or match?({:ok, []}, result)
      end)
    end
  end

  describe "get_events/3" do
    test "accepts start and end time parameters" do
      client = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      capture_log(fn ->
        result = Provider.get_events(client, start_time, end_time)
        # Should fail immediately
        assert match?({:error, _}, result) or match?({:ok, []}, result)
      end)
    end
  end

  describe "create_event/2" do
    test "accepts event data for creation" do
      client = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      event_data = %{
        summary: "Test Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      capture_log(fn ->
        result = Provider.create_event(client, event_data)
        assert match?({:error, _}, result)
      end)
    end
  end

  describe "update_event/3" do
    test "accepts uid and event data for update" do
      client = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      uid = "test-event-123"

      event_data = %{
        summary: "Updated Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      capture_log(fn ->
        result = Provider.update_event(client, uid, event_data)
        assert match?({:error, _}, result)
      end)
    end
  end

  describe "delete_event/2" do
    test "accepts uid for deletion" do
      client = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      uid = "test-event-123"

      capture_log(fn ->
        result = Provider.delete_event(client, uid)
        assert match?({:error, _}, result)
      end)
    end
  end

  describe "test_connection/2" do
    test "returns error for invalid credentials" do
      integration = %{
        base_url: "http://localhost:1",
        username: "invalid",
        password: "wrong",
        calendar_paths: []
      }

      capture_log(fn ->
        result = Provider.test_connection(integration)
        assert {:error, _message} = result
      end)
    end

    test "accepts options with metadata" do
      integration = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      opts = [metadata: %{ip: "192.168.1.1"}]

      capture_log(fn ->
        result = Provider.test_connection(integration, opts)
        assert {:error, _message} = result
      end)
    end
  end

  describe "discover_calendars/2" do
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

    test "accepts options with IP address for rate limiting" do
      client = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :caldav
      }

      opts = [metadata: %{ip: "192.168.1.1"}]

      capture_log(fn ->
        result = Provider.discover_calendars(client, opts)
        assert {:error, _message} = result
      end)
    end
  end
end
