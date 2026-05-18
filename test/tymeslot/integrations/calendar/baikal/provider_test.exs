defmodule Tymeslot.Integrations.Calendar.Baikal.ProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Tymeslot.CalDAVTestHelpers

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Baikal.Provider

  setup do
    CalendarCircuitBreaker.reset(:baikal)
    :ok
  end

  describe "provider_type/0" do
    test "returns :baikal" do
      assert Provider.provider_type() == :baikal
    end
  end

  describe "display_name/0" do
    test "returns Baikal branding" do
      assert Provider.display_name() == "Baikal"
    end
  end

  describe "config_schema/0" do
    test "includes the standard CalDAV base fields" do
      schema = Provider.config_schema()
      assert_has_caldav_base_fields(schema)
    end

    test "mentions /dav.php in the base_url description" do
      schema = Provider.config_schema()
      assert String.contains?(schema[:base_url][:description], "/dav.php")
    end

    test "calendar_paths is optional" do
      schema = Provider.config_schema()
      assert schema[:calendar_paths][:type] == :list
      assert schema[:calendar_paths][:required] == false
    end
  end

  describe "validate_config/1" do
    import Tymeslot.CalendarProviderValidationCases

    test "validates basic required fields" do
      test_basic_validation(Provider, "https://baikal.example.com/dav.php")
    end

    test "accepts a valid config (connection fails without live server)" do
      config = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret"
      }

      capture_log(fn ->
        result = Provider.validate_config(config)
        assert match?({:error, _}, result)
      end)
    end
  end

  describe "new/1" do
    test "builds a client tagged :baikal" do
      config = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret",
        calendar_paths: ["/dav.php/calendars/alice/default/"]
      }

      client = Provider.new(config)

      assert client.provider == :baikal
      assert client.username == "alice"
      assert client.verify_ssl == true
      assert client.calendar_paths == ["/dav.php/calendars/alice/default/"]
    end

    test "trims trailing slash from base_url" do
      config = %{
        base_url: "https://baikal.example.com/dav.php/",
        username: "alice",
        password: "secret"
      }

      client = Provider.new(config)
      assert client.base_url == "https://baikal.example.com/dav.php"
    end

    test "returns empty calendar_paths when none configured and no calendar_names given" do
      config = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret"
      }

      client = Provider.new(config)
      assert client.calendar_paths == []
    end

    test "builds calendar paths from calendar_names and username" do
      config = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret",
        calendar_names: ["default", "work"]
      }

      client = Provider.new(config)

      assert Enum.member?(client.calendar_paths, "/dav.php/calendars/alice/default/")
      assert Enum.member?(client.calendar_paths, "/dav.php/calendars/alice/work/")
    end

    test "format_baikal_path is idempotent — does not double-prefix already-formatted paths" do
      prefix = "/dav.php/calendars/alice/default/"

      config = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret",
        calendar_paths: [prefix]
      }

      client = Provider.new(config)
      assert client.calendar_paths == [prefix]
    end
  end

  describe "setup_component/0" do
    test "returns the BaikalConfig LiveComponent module" do
      assert Provider.setup_component() ==
               TymeslotWeb.Components.Dashboard.Integrations.Calendar.BaikalConfig
    end
  end

  describe "test_connection/2" do
    test "returns Baikal-specific success message on 207" do
      integration = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: :baikal
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert {:ok, message} = Provider.test_connection(integration)
      assert String.contains?(message, "Baikal")
    end

    test "returns authentication-failure message on 401" do
      integration = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "wrong",
        calendar_paths: [],
        provider: :baikal
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, message} = Provider.test_connection(integration)
      assert message =~ "Authentication failed"
    end

    test "returns not-found message on 404 with RFC 4791 fallback also 404" do
      integration = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: :baikal
      }

      # Primary PROPFIND probe → 404
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      # RFC 4791 fallback probe on "/" → also 404
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, message} = Provider.test_connection(integration)
      assert message =~ "not found" or message =~ "not accessible" or message =~ "/dav.php"
    end

    test "accepts IP metadata option" do
      integration = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: :baikal
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert {:ok, _message} =
               Provider.test_connection(integration, metadata: %{ip: "192.168.1.1"})
    end
  end

  describe "discover_calendars/2" do
    test "returns error when server is unreachable" do
      client = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: :baikal
      }

      capture_log(fn ->
        result = Provider.discover_calendars(client)
        assert {:error, _message} = result
      end)
    end

    test "accepts IP metadata via opts" do
      client = %{
        base_url: "https://baikal.example.com/dav.php",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: :baikal
      }

      opts = [metadata: %{ip: "10.0.0.1"}]

      capture_log(fn ->
        result = Provider.discover_calendars(client, opts)
        assert {:error, _message} = result
      end)
    end
  end
end
