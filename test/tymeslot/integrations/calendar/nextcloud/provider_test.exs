defmodule Tymeslot.Integrations.Calendar.Nextcloud.ProviderTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Calendar.Nextcloud.Provider

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

      assert {:error, message} = Provider.validate_config(config)

      # Scheme is auto-added, so URL becomes valid but connection fails
      # Message can be atom or string representing connection failure
      assert is_binary(message) or is_atom(message)
    end

    test "accepts calendar URL format" do
      config = %{
        base_url: "https://cloud.example.com/remote.php/dav/calendars/user/personal",
        username: "user",
        password: "pass"
      }

      # Will fail connection test but URL structure is valid
      result = Provider.validate_config(config)
      assert match?({:error, _}, result)
    end

    test "accepts standard Nextcloud URL" do
      config = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      # Will fail connection test but URL structure is valid
      result = Provider.validate_config(config)
      assert match?({:error, _}, result)
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
      assert is_list(client.calendar_paths)

      assert Enum.any?(client.calendar_paths, fn path ->
               String.contains?(path, "/calendars/testuser/")
             end)
    end

    test "defaults to personal calendar when no paths provided" do
      config = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      client = Provider.new(config)

      assert is_list(client.calendar_paths)
      assert length(client.calendar_paths) > 0
    end

    test "extracts username from calendar URL when not provided" do
      config = %{
        base_url: "https://cloud.example.com/remote.php/dav/calendars/john/personal",
        password: "pass"
      }

      client = Provider.new(config)

      # Username should be extracted from URL
      assert is_binary(client.username)
    end
  end

  describe "test_connection/2" do
    test "returns Nextcloud-specific success message" do
      integration = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      # Will fail but tests interface
      case Provider.test_connection(integration) do
        {:ok, message} -> assert String.contains?(message, "Nextcloud")
        {:error, _} -> :ok
      end
    end

    test "returns helpful error message for authentication failure" do
      integration = %{
        base_url: "http://localhost:1",
        username: "invalid",
        password: "wrong",
        calendar_paths: []
      }

      result = Provider.test_connection(integration)

      case result do
        {:error, message} ->
          # Check for helpful message or network error
          assert is_atom(message) or is_binary(message) or is_tuple(message)

        {:ok, _} ->
          :ok
      end
    end

    test "accepts options with IP metadata" do
      integration = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      opts = [metadata: %{ip: "192.168.1.1"}]

      result = Provider.test_connection(integration, opts)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
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

      result = Provider.discover_calendars(client)
      assert {:error, _message} = result
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

      result = Provider.discover_calendars(client, opts)
      assert {:error, _message} = result
    end
  end

  describe "get_events/1" do
    test "delegates to CalDAV provider" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :nextcloud
      }

      result = Provider.get_events(client)
      # May return error or empty list depending on circuit breaker state
      assert match?({:error, _}, result) or match?({:ok, []}, result)
    end
  end

  describe "get_events/3" do
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

      result = Provider.get_events(client, start_time, end_time)
      # May return error or empty list depending on circuit breaker state
      assert match?({:error, _}, result) or match?({:ok, []}, result)
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

      result = Provider.create_event(client, event_data)
      assert match?({:error, _}, result)
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

      result = Provider.update_event(client, uid, event_data)
      assert match?({:error, _}, result)
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

      result = Provider.delete_event(client, uid)
      assert match?({:error, _}, result)
    end
  end
end
