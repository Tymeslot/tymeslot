defmodule Tymeslot.Integrations.Calendar.MailboxOrg.ProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Tymeslot.CalDAVTestHelpers

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.MailboxOrg.Provider

  setup do
    CalendarCircuitBreaker.reset(:mailbox_org)
    :ok
  end

  describe "provider_type/0" do
    test "returns :mailbox_org" do
      assert Provider.provider_type() == :mailbox_org
    end
  end

  describe "display_name/0" do
    test "uses lowercase mailbox.org branding" do
      assert Provider.display_name() == "mailbox.org"
    end
  end

  describe "config_schema/0" do
    test "includes the standard CalDAV base fields" do
      schema = Provider.config_schema()
      assert_has_caldav_base_fields(schema)
    end

    test "defaults base_url to https://dav.mailbox.org" do
      schema = Provider.config_schema()
      assert schema[:base_url][:default] == "https://dav.mailbox.org"
    end

    test "documents app-specific password requirement for 2FA users" do
      schema = Provider.config_schema()

      assert String.contains?(
               schema[:password][:description],
               "application-specific password"
             )
    end
  end

  describe "validate_config/1" do
    import Tymeslot.CalendarProviderValidationCases

    test "validates basic required fields" do
      assert :ok = test_basic_validation(Provider, "https://dav.mailbox.org")
    end

    test "rejects HTTP for the public mailbox.org host" do
      config = %{
        base_url: "http://dav.mailbox.org",
        username: "you@mailbox.org",
        password: "pass"
      }

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "HTTPS")
    end

    test "accepts HTTPS but reports a connection failure when no server is reachable" do
      config = %{
        base_url: "https://dav.mailbox.org",
        username: "you@mailbox.org",
        password: "pass"
      }

      capture_log(fn ->
        assert match?({:error, _}, Provider.validate_config(config))
      end)
    end
  end

  describe "new/1" do
    test "builds a CalDAV client tagged with provider :mailbox_org" do
      config = %{
        base_url: "https://dav.mailbox.org",
        username: "you@mailbox.org",
        password: "pass",
        calendar_paths: ["/caldav/Y2FsOi8vMC8zMg/"]
      }

      client = Provider.new(config)

      assert client.provider == :mailbox_org
      assert client.username == "you@mailbox.org"
      assert client.calendar_paths == ["/caldav/Y2FsOi8vMC8zMg/"]
      assert client.verify_ssl == true
    end

    test "trims trailing slash from the base URL" do
      config = %{
        base_url: "https://dav.mailbox.org/",
        username: "you@mailbox.org",
        password: "pass"
      }

      client = Provider.new(config)
      assert client.base_url == "https://dav.mailbox.org"
    end

    test "falls back to the documented default base URL when none is supplied" do
      client =
        Provider.new(%{
          base_url: nil,
          username: "you@mailbox.org",
          password: "pass"
        })

      assert client.base_url == "https://dav.mailbox.org"
    end

    test "leaves calendar_paths empty when none are provided (auto-discovery)" do
      client =
        Provider.new(%{
          base_url: "https://dav.mailbox.org",
          username: "you@mailbox.org",
          password: "pass"
        })

      assert client.calendar_paths == []
    end
  end

  describe "setup_component/0" do
    test "points at the matching LiveComponent" do
      assert Provider.setup_component() ==
               TymeslotWeb.Components.Dashboard.Integrations.Calendar.MailboxOrgConfig
    end
  end
end
