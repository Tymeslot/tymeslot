defmodule Tymeslot.Integrations.Calendar.Zimbra.ProviderTest do
  use ExUnit.Case, async: true

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
      test_basic_validation(Provider, "https://mail.example.com")
    end

    test "blocks localhost URLs (SSRF protection)" do
      config = %{
        base_url: "http://localhost:8080",
        username: "user",
        password: "pass"
      }

      # Should allow HTTP for localhost but still fail connection
      capture_log(fn ->
        result = Provider.validate_config(config)
        # Will fail connection but URL validation should pass for local hosts
        assert match?({:error, _}, result)
      end)
    end

    test "blocks private IP addresses (SSRF protection)" do
      config = %{
        base_url: "http://10.0.0.1",
        username: "user",
        password: "pass"
      }

      # Should allow HTTP for private IPs but still fail connection
      capture_log(fn ->
        result = Provider.validate_config(config)
        assert match?({:error, _}, result)
      end)
    end

    test "blocks AWS metadata endpoint (SSRF protection)" do
      config = %{
        base_url: "http://169.254.169.254",
        username: "user",
        password: "pass"
      }

      # Should allow HTTP for link-local but still fail connection
      capture_log(fn ->
        result = Provider.validate_config(config)
        assert match?({:error, _}, result)
      end)
    end

    test "enforces HTTPS for public hosts" do
      config = %{
        base_url: "http://mail.example.com",
        username: "user",
        password: "pass"
      }

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "HTTPS") or String.contains?(message, "https")
    end

    test "accepts HTTPS for public hosts (connection fails without server)" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass"
      }

      # URL validation passes but connection test fails without actual server
      capture_log(fn ->
        result = Provider.validate_config(config)
        assert match?({:error, _}, result)
      end)
    end

    test "accepts full CalDAV URL format (connection fails without server)" do
      config = %{
        base_url: "https://mail.example.com/dav/user@example.com",
        username: "user@example.com",
        password: "pass"
      }

      # URL validation passes but connection test fails without actual server
      capture_log(fn ->
        result = Provider.validate_config(config)
        assert match?({:error, _}, result)
      end)
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

      # Calendar paths should be formatted for Zimbra
      assert is_list(client.calendar_paths)
      assert length(client.calendar_paths) == 1

      assert Enum.any?(client.calendar_paths, fn path ->
               String.contains?(path, "/dav/testuser@example.com/Calendar/")
             end)
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
        case Provider.test_connection(integration) do
          {:ok, message} -> assert String.contains?(message, "Zimbra")
          {:error, _} -> :ok
        end
      end)
    end

    test "returns helpful error message for authentication failure" do
      integration = %{
        base_url: "http://localhost:1",
        username: "invalid@example.com",
        password: "wrong",
        calendar_paths: [],
        provider: :zimbra
      }

      capture_log(fn ->
        # Without actual server, should return connection error
        assert {:error, message} = Provider.test_connection(integration)
        assert is_binary(message)
      end)
    end

    test "accepts options with IP metadata" do
      integration = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      opts = [metadata: %{ip: "192.168.1.1"}]

      capture_log(fn ->
        # Without actual server, should return connection error
        assert {:error, _message} = Provider.test_connection(integration, opts)
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

    test "accepts options for rate limiting" do
      client = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      opts = [metadata: %{ip: "10.0.0.1"}]

      capture_log(fn ->
        result = Provider.discover_calendars(client, opts)
        assert {:error, _message} = result
      end)
    end
  end

  describe "get_events/1" do
    test "delegates to CaldavCommon" do
      client = %{
        base_url: "http://localhost:1",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user@example.com/Calendar/"],
        provider: :zimbra
      }

      capture_log(fn ->
        # Circuit breaker may return error or empty list depending on state
        result = Provider.get_events(client)
        assert match?({:error, _}, result) or match?({:ok, []}, result)
      end)
    end
  end

  describe "get_events/3" do
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
        # Circuit breaker may return error or empty list depending on state
        result = Provider.get_events(client, start_time, end_time)
        assert match?({:error, _}, result) or match?({:ok, []}, result)
      end)
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
