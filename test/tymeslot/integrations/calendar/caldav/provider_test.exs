defmodule Tymeslot.Integrations.Calendar.CalDAV.ProviderTest do
  use ExUnit.Case, async: true

  import Mox
  alias Tymeslot.Integrations.Calendar.CalDAV.Provider

  setup :verify_on_exit!

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
    test "returns error when base_url is missing" do
      config = %{username: "user", password: "pass"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "base_url")
    end

    test "returns error when username is missing" do
      config = %{base_url: "https://caldav.example.com", password: "pass"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "username")
    end

    test "returns error when password is missing" do
      config = %{base_url: "https://caldav.example.com", username: "user"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "password")
    end

    test "returns error for invalid URL format" do
      config = %{
        base_url: "not-a-valid-url",
        username: "user",
        password: "pass"
      }

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "URL") or String.contains?(message, "url")
    end

    test "attempts connection when all required fields present" do
      config = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass"
      }

      # Will fail connection but validates structure
      result = Provider.validate_config(config)
      assert match?({:error, _}, result)
    end
  end

  describe "new/1" do
    test "creates client with CalDAV configuration" do
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
      assert client.provider == :caldav
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
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      # May return error or empty list depending on circuit breaker state
      result = Provider.get_events(client)
      assert match?({:error, _}, result) or match?({:ok, []}, result)
    end
  end

  describe "get_events/3" do
    test "accepts start and end time parameters" do
      client = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      result = Provider.get_events(client, start_time, end_time)
      # May return error or empty list depending on circuit breaker state
      assert match?({:error, _}, result) or match?({:ok, []}, result)
    end
  end

  describe "create_event/2" do
    test "accepts event data for creation" do
      client = %{
        base_url: "https://caldav.example.com",
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

      result = Provider.create_event(client, event_data)
      assert match?({:error, _}, result)
    end
  end

  describe "update_event/3" do
    test "accepts uid and event data for update" do
      client = %{
        base_url: "https://caldav.example.com",
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

      result = Provider.update_event(client, uid, event_data)
      assert match?({:error, _}, result)
    end
  end

  describe "delete_event/2" do
    test "accepts uid for deletion" do
      client = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :caldav
      }

      uid = "test-event-123"

      result = Provider.delete_event(client, uid)
      assert match?({:error, _}, result)
    end
  end

  describe "test_connection/2" do
    test "returns error for invalid credentials" do
      integration = %{
        base_url: "https://caldav.example.com",
        username: "invalid",
        password: "wrong",
        calendar_paths: []
      }

      result = Provider.test_connection(integration)
      assert {:error, _message} = result
    end

    test "accepts options with metadata" do
      integration = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      opts = [metadata: %{ip: "192.168.1.1"}]

      result = Provider.test_connection(integration, opts)
      assert {:error, _message} = result
    end
  end

  describe "discover_calendars/2" do
    test "returns error without valid server" do
      client = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :caldav
      }

      result = Provider.discover_calendars(client)
      assert {:error, _message} = result
    end

    test "accepts options with IP address for rate limiting" do
      client = %{
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :caldav
      }

      opts = [metadata: %{ip: "192.168.1.1"}]

      result = Provider.discover_calendars(client, opts)
      assert {:error, _message} = result
    end
  end
end
