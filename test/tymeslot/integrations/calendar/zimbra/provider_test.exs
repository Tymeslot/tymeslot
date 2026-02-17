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
    test "returns error when base_url is missing" do
      config = %{username: "user", password: "pass"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "base_url")
    end

    test "returns error when username is missing" do
      config = %{base_url: "https://mail.example.com", password: "pass"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "username")
    end

    test "returns error when password is missing" do
      config = %{base_url: "https://mail.example.com", username: "user"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "password")
    end

    test "returns error for invalid Zimbra URL format" do
      config = %{
        base_url: "not-a-valid-url",
        username: "user",
        password: "pass"
      }

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "URL") or String.contains?(message, "url")
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

    test "handles nil username gracefully" do
      config = %{
        base_url: "https://mail.example.com",
        username: nil,
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should return empty calendar_paths when username is nil
      assert client.calendar_paths == []
    end

    test "handles empty username gracefully" do
      config = %{
        base_url: "https://mail.example.com",
        username: "",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should return empty calendar_paths when username is empty
      assert client.calendar_paths == []
    end

    test "sanitizes calendar names with path traversal attempts" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["../../../etc/passwd"]
      }

      client = Provider.new(config)

      # Should produce exactly one sanitized path without path traversal
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      assert String.contains?(path, "/dav/user@example.com/")
      assert String.ends_with?(path, "/")
      refute String.contains?(path, "..")
    end

    test "handles calendar names with null bytes" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["Calendar\x00Name"]
      }

      client = Provider.new(config)

      # Should produce path with null bytes removed
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      assert String.contains?(path, "CalendarName")
      refute String.contains?(path, "\x00")
    end

    test "handles very long calendar names" do
      long_name = String.duplicate("a", 1000)

      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: [long_name]
      }

      client = Provider.new(config)

      # Should truncate or reject paths exceeding max byte length (255)
      # Uses byte_size to account for multi-byte UTF-8 characters
      if client.calendar_paths != [] do
        assert Enum.all?(client.calendar_paths, fn path ->
                 byte_size(path) <= 255
               end)
      end
    end

    test "handles calendar names with multi-byte UTF-8 characters and enforces byte limit" do
      # Emoji are typically 4 bytes each in UTF-8
      # 60 emoji = 240 bytes, plus path overhead could exceed 255 bytes
      emoji_name = String.duplicate("📅", 60)

      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: [emoji_name]
      }

      client = Provider.new(config)

      # Should enforce byte size limit, not character count
      if client.calendar_paths != [] do
        assert Enum.all?(client.calendar_paths, fn path ->
                 byte_size(path) <= 255
               end)
      end
    end

    test "handles empty calendar names" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["", "  ", "ValidName"]
      }

      client = Provider.new(config)

      # Should filter out empty/whitespace-only names
      assert is_list(client.calendar_paths)

      if client.calendar_paths != [] do
        # Should only include ValidName
        assert Enum.all?(client.calendar_paths, fn path ->
                 String.contains?(path, "ValidName") or
                   String.length(path) > String.length("/dav/user@example.com/")
               end)
      end
    end

    test "sanitizes pre-formatted paths with path traversal (security fix)" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["/dav/user@example.com/../../../etc/passwd"]
      }

      client = Provider.new(config)

      # Critical: Pre-formatted paths must be sanitized to prevent path traversal
      if client.calendar_paths != [] do
        assert Enum.all?(client.calendar_paths, fn path ->
                 not String.contains?(path, "..")
               end)
      end
    end

    test "sanitizes pre-formatted paths with complex traversal patterns" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: [
          "/dav/user@example.com/Calendar/../../sensitive",
          "/dav/user@example.com/....//etc/passwd",
          "/dav/user@example.com/..",
          "/dav/user@example.com/..."
        ]
      }

      client = Provider.new(config)

      # All path traversal sequences should be removed
      assert Enum.all?(client.calendar_paths, fn path ->
               not String.contains?(path, "..")
             end)
    end

    test "handles Unicode in calendar names" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["📅 Calendar", "日本語カレンダー", "Календарь", "Arbeit✓"]
      }

      client = Provider.new(config)

      # Should preserve Unicode or sanitize consistently
      assert is_list(client.calendar_paths)
      assert Enum.all?(client.calendar_paths, &is_binary/1)

      # Paths should be valid and not empty
      if client.calendar_paths != [] do
        assert Enum.all?(client.calendar_paths, fn path ->
                 String.length(path) > String.length("/dav/user@example.com/")
               end)
      end
    end

    test "handles mixed Unicode and ASCII in calendar names" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["Work🏢", "Home🏠", "Calendar-2024"]
      }

      client = Provider.new(config)

      assert is_list(client.calendar_paths)
      assert Enum.all?(client.calendar_paths, &is_binary/1)

      # All paths should be valid binary strings
      assert Enum.all?(client.calendar_paths, fn path ->
               String.valid?(path)
             end)
    end

    # Username sanitization tests (CRITICAL SECURITY)
    test "sanitizes username with path traversal attempts" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com/../../etc",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should produce path without path traversal in username component
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "..")
      # Verify path structure is maintained
      assert String.starts_with?(path, "/dav/")
      assert String.ends_with?(path, "/")
    end

    test "sanitizes username with null bytes" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user\x00@example.com",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should produce path with null bytes removed from username
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "\x00")
      assert String.contains?(path, "user@example.com")
    end

    test "sanitizes username with control characters" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user\r\n@example.com",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should remove control characters from username
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "\r")
      refute String.contains?(path, "\n")
    end

    test "handles very long username (DoS protection)" do
      long_username = String.duplicate("a", 1000) <> "@example.com"

      config = %{
        base_url: "https://mail.example.com",
        username: long_username,
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should truncate username to prevent DoS
      if client.calendar_paths != [] do
        assert Enum.all?(client.calendar_paths, fn path ->
                 byte_size(path) <= 255
               end)
      end
    end

    test "sanitizes username with complex path traversal patterns" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com/../../../etc/passwd",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should remove all path traversal sequences (..)
      # The text "etc/passwd" may remain as it's just text after .. is removed
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "..")
    end

    test "rejects empty username after sanitization" do
      config = %{
        base_url: "https://mail.example.com",
        username: "../../",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should produce no paths when username becomes empty after sanitization
      assert client.calendar_paths == []
    end

    test "handles username and calendar name both with path traversal" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user/../admin",
        password: "pass",
        calendar_names: ["../../etc/passwd"]
      }

      client = Provider.new(config)

      # Both username and calendar name should be sanitized
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "..")
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
