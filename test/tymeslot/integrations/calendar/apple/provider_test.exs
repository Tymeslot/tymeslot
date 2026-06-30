defmodule Tymeslot.Integrations.Calendar.Apple.ProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Tymeslot.CalDAVTestHelpers

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Apple.Provider

  setup do
    CalendarCircuitBreaker.reset(:apple)
    :ok
  end

  describe "provider_type/0" do
    test "returns :apple" do
      assert Provider.provider_type() == :apple
    end
  end

  describe "display_name/0" do
    test "uses Apple iCloud branding" do
      assert Provider.display_name() == "Apple iCloud"
    end
  end

  describe "config_schema/0" do
    test "includes the standard CalDAV base fields" do
      schema = Provider.config_schema()
      assert_has_caldav_base_fields(schema)
    end

    test "defaults base_url to https://caldav.icloud.com" do
      schema = Provider.config_schema()
      assert schema[:base_url][:default] == "https://caldav.icloud.com"
    end

    test "documents the app-specific password requirement" do
      schema = Provider.config_schema()

      assert String.contains?(
               schema[:password][:description],
               "app-specific password"
             )
    end
  end

  describe "validate_config/1" do
    test "rejects HTTP for the public iCloud host" do
      config = %{
        base_url: "http://caldav.icloud.com",
        username: "you@icloud.com",
        password: "abcd-efgh-ijkl-mnop"
      }

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "HTTPS")
    end

    test "accepts HTTPS but reports a connection failure when no server is reachable" do
      config = %{
        base_url: "https://caldav.icloud.com",
        username: "you@icloud.com",
        password: "abcd-efgh-ijkl-mnop"
      }

      capture_log(fn ->
        assert match?({:error, _}, Provider.validate_config(config))
      end)
    end
  end

  describe "new/1" do
    test "builds a CalDAV client tagged with provider :apple" do
      config = %{
        base_url: "https://caldav.icloud.com",
        username: "you@icloud.com",
        password: "abcd-efgh-ijkl-mnop",
        calendar_paths: ["/19428228001/calendars/home/"]
      }

      client = Provider.new(config)

      assert client.provider == :apple
      assert client.username == "you@icloud.com"
      assert client.calendar_paths == ["/19428228001/calendars/home/"]
      assert client.verify_ssl == true
    end

    test "trims trailing slash from the base URL" do
      config = %{
        base_url: "https://caldav.icloud.com/",
        username: "you@icloud.com",
        password: "abcd-efgh-ijkl-mnop"
      }

      client = Provider.new(config)
      assert client.base_url == "https://caldav.icloud.com"
    end

    test "falls back to the fixed iCloud base URL when none is supplied" do
      client =
        Provider.new(%{
          base_url: nil,
          username: "you@icloud.com",
          password: "abcd-efgh-ijkl-mnop"
        })

      assert client.base_url == "https://caldav.icloud.com"
    end

    test "leaves calendar_paths empty when none are provided (auto-discovery)" do
      client =
        Provider.new(%{
          base_url: "https://caldav.icloud.com",
          username: "you@icloud.com",
          password: "abcd-efgh-ijkl-mnop"
        })

      assert client.calendar_paths == []
    end
  end

  describe "setup_component/0" do
    test "points at the matching LiveComponent" do
      assert Provider.setup_component() ==
               TymeslotWeb.Components.Dashboard.Integrations.Calendar.AppleConfig
    end
  end
end
