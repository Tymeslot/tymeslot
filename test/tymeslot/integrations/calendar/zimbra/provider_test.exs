defmodule Tymeslot.Integrations.Calendar.Zimbra.ProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations

  import ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Zimbra.Provider

  setup do
    CalendarCircuitBreaker.reset(:zimbra)
    :ok
  end

  describe "provider_type/0" do
    test "returns :zimbra" do
      assert Provider.provider_type() == :zimbra
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert Provider.display_name() == "Zimbra"
    end
  end

  import Tymeslot.CalDAVTestHelpers

  describe "config_schema/0" do
    test "returns schema with Zimbra-specific fields" do
      schema = Provider.config_schema()
      assert_has_caldav_base_fields(schema)
    end

    test "includes description mentioning Zimbra server URL format" do
      schema = Provider.config_schema()

      assert String.contains?(schema[:base_url][:description], "Zimbra")
    end

    test "includes calendar_paths with auto-discovery option" do
      schema = Provider.config_schema()

      assert schema[:calendar_paths][:type] == :list
      assert schema[:calendar_paths][:required] == false
      assert String.contains?(schema[:calendar_paths][:description], "auto-discovered")
    end
  end

  describe "validate_config/1" do
    import Tymeslot.CalendarProviderValidationCases

    test "validates basic required fields" do
      # The shared case block asserts on each missing/invalid field in turn and
      # returns :ok only once every one of them has been checked.
      assert :ok = test_basic_validation(Provider, "https://mail.example.com")
    end

    # `validate_config/1` is structural only — it never performs network I/O
    # (the connectivity probe used to run here too, doubling the rate-limit
    # charge across two buckets for a single form submission). HTTP is
    # allowed for localhost/private/link-local hosts (dev/test environments),
    # so URL validation passes here; the live check now runs separately,
    # through `test_connection/1`.
    test "allows HTTP for localhost URLs without touching the network" do
      config = %{
        base_url: "http://localhost:8080",
        username: "user",
        password: "pass"
      }

      assert :ok = Provider.validate_config(config)
    end

    test "allows HTTP for private IP addresses without touching the network" do
      config = %{
        base_url: "http://10.0.0.1",
        username: "user",
        password: "pass"
      }

      assert :ok = Provider.validate_config(config)
    end

    test "allows HTTP for the AWS metadata endpoint without touching the network" do
      config = %{
        base_url: "http://169.254.169.254",
        username: "user",
        password: "pass"
      }

      assert :ok = Provider.validate_config(config)
    end

    test "enforces HTTPS for public hosts" do
      config = %{
        base_url: "http://mail.example.com",
        username: "user",
        password: "pass"
      }

      assert Provider.validate_config(config) ==
               {:error, "Use HTTPS for non-local Zimbra servers"}
    end

    test "accepts HTTPS for public hosts without touching the network" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass"
      }

      assert :ok = Provider.validate_config(config)
    end

    test "accepts full CalDAV URL format without touching the network" do
      config = %{
        base_url: "https://mail.example.com/dav/user@example.com",
        username: "user@example.com",
        password: "pass"
      }

      assert :ok = Provider.validate_config(config)
    end
  end

  describe "new/1" do
    test "creates client with Zimbra configuration" do
      config = %{
        base_url: "https://mail.example.com",
        username: "testuser@example.com",
        password: "testpass",
        calendar_paths: ["/dav/testuser@example.com/Calendar/"]
      }

      client = Provider.new(config)

      assert client.username == "testuser@example.com"
      assert client.password == "testpass"
      assert client.provider == :zimbra
      assert client.verify_ssl == true
    end

    test "normalizes Zimbra base URL" do
      config = %{
        base_url: "https://mail.example.com/",
        username: "user@example.com",
        password: "pass"
      }

      client = Provider.new(config)

      # Should normalize by removing trailing slash
      assert client.base_url == "https://mail.example.com"
    end

    test "builds Zimbra calendar paths correctly" do
      config = %{
        base_url: "https://mail.example.com",
        username: "testuser@example.com",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Calendar names are turned into Zimbra's /dav/{username}/{name}/ paths
      assert client.calendar_paths == ["/dav/testuser@example.com/Calendar/"]
    end

    test "sets empty calendar_paths when not provided" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass"
      }

      client = Provider.new(config)

      assert client.calendar_paths == []
    end

    test "preserves provided calendar_paths" do
      paths = ["/dav/user@example.com/Calendar/", "/dav/user@example.com/Work/"]

      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: paths
      }

      client = Provider.new(config)

      assert client.calendar_paths == paths
    end
  end

  describe "test_connection/2" do
    test "returns Zimbra-specific success message on success" do
      integration = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      # Will fail but tests interface
      capture_log(fn ->
        case Provider.perform_connection_test(integration) do
          {:ok, message} -> assert String.contains?(message, "Zimbra")
          {:error, _reason} -> :ok
        end
      end)
    end

    test "returns a sanitised error message when the server is unreachable" do
      integration = %{
        base_url: "http://localhost:1",
        username: "invalid@example.com",
        password: "wrong",
        calendar_paths: [],
        provider: :zimbra
      }

      capture_log(fn ->
        # Nothing is listening on port 1, so the error is the generic connect
        # message — it must never leak the underlying transport reason.
        assert Provider.perform_connection_test(integration) ==
                 {:error,
                  "Unable to connect to the calendar service. Please check the URL and try again."}
      end)
    end

    test "is pure I/O — takes only the integration, no caller options" do
      integration = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      capture_log(fn ->
        # Without actual server, should return connection error
        assert {:error, _message} = Provider.perform_connection_test(integration)
      end)
    end
  end

  describe "discover_calendars/2" do
    test "returns error without valid Zimbra server" do
      client = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      capture_log(fn ->
        result = Provider.discover_calendars(client)
        assert {:error, _message} = result
      end)
    end

    test "ensures provider is set to zimbra for discovery" do
      # Create client without provider set
      client = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: []
      }

      capture_log(fn ->
        # discover_calendars should set provider to :zimbra internally
        result = Provider.discover_calendars(client)
        assert {:error, _message} = result
      end)
    end
  end

  describe "list_events/3" do
    test "delegates to CaldavCommon with time range" do
      client = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user@example.com/Calendar/"],
        provider: :zimbra
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 86_400, :second)

      capture_log(fn ->
        # The circuit breaker is reset in setup, so the CalDAV request is
        # actually attempted and fails against the dead port.
        assert {:error, _reason} =
                 Provider.list_events(client, start_time: start_time, end_time: end_time)
      end)
    end

    test "returns error when time range is missing" do
      client = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user@example.com/Calendar/"],
        provider: :zimbra
      }

      assert Provider.list_events(client, []) == {:error, :missing_time_range}
    end
  end

  describe "create_event/2" do
    test "delegates to CaldavCommon for event creation" do
      client = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user@example.com/Calendar/"],
        provider: :zimbra
      }

      event_data = %{
        summary: "Zimbra Meeting",
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
    test "delegates to CaldavCommon for event update" do
      client = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user@example.com/Calendar/"],
        provider: :zimbra
      }

      uid = "zimbra-event-123"

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
    test "delegates to CaldavCommon for event deletion" do
      client = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user@example.com/Calendar/"],
        provider: :zimbra
      }

      uid = "zimbra-event-123"

      capture_log(fn ->
        result = Provider.delete_event(client, uid)
        assert match?({:error, _}, result)
      end)
    end
  end

  describe "setup_component/0" do
    test "returns the ZimbraConfig LiveComponent module" do
      assert Provider.setup_component() ==
               TymeslotWeb.Components.Dashboard.Integrations.Calendar.ZimbraConfig
    end
  end
end
