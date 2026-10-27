defmodule Tymeslot.Integrations.Calendar.Zimbra.ProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Zimbra.Provider

  setup :verify_on_exit!

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

    # The scheme-less form is how this field is most commonly got wrong, and
    # `URI.parse/1` gives it `scheme: nil`, which lands in the same refusal
    # branch as `ftp://`. Both must carry the provider's own guidance rather
    # than the shared module's generic "start with https://" default.
    test "describes the expected Zimbra URL shape for a scheme-less URL" do
      config = %{base_url: "mail.example.com", username: "user", password: "pass"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "Invalid Zimbra URL")
    end

    test "describes the expected Zimbra URL shape for a non-HTTP scheme" do
      config = %{base_url: "ftp://mail.example.com", username: "user", password: "pass"}

      assert {:error, message} = Provider.validate_config(config)
      assert String.contains?(message, "Invalid Zimbra URL")
    end

    test "validates basic required fields" do
      # The shared case block asserts on each missing/invalid field in turn and
      # returns :ok only once every one of them has been checked.
      assert :ok = test_basic_validation(Provider, "https://mail.example.com")
    end

    # `validate_config/1` is structural only: it never performs network I/O.
    # Private, loopback and link-local addresses are refused like every other
    # CalDAV-family member's, unless the operator opts out
    # (`ALLOW_PRIVATE_IPS_FOR_CALENDAR`, covered family-wide in
    # `CalDAV.FamilyUrlValidationTest`).
    for url <- ["http://localhost:8080", "http://10.0.0.1", "http://169.254.169.254"] do
      test "refuses the private address #{url}" do
        config = %{base_url: unquote(url), username: "user", password: "pass"}

        assert Provider.validate_config(config) ==
                 {:error, "Private or local network addresses are not allowed"}
      end
    end

    test "enforces HTTPS for public hosts" do
      config = %{
        base_url: "http://mail.example.com",
        username: "user",
        password: "pass"
      }

      assert Provider.validate_config(config) ==
               {:error, "Use HTTPS for non-local calendar servers"}
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
    test "says a refused server address is a private one" do
      integration = %{
        base_url: "http://localhost:1",
        username: "invalid@example.com",
        password: "wrong",
        calendar_paths: [],
        provider: :zimbra
      }

      # The loopback URL never reaches a socket: `CalDAV.Discovery` refuses it
      # up front. Zimbra rewrites its other failures into generic sentences,
      # but this refusal keeps its meaning, so the owner looks at the address
      # rather than at the URL's spelling.
      assert Provider.perform_connection_test(integration) ==
               {:error, "Private or local network addresses are not allowed"}
    end

    test "is pure I/O — takes only the integration, no caller options" do
      integration = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      # The arity is the point: the call below passes the integration alone,
      # and the stubbed PROPFIND proves the probe was really issued rather
      # than the call being rejected for a missing options argument.
      assert Provider.perform_connection_test(integration) ==
               {:ok, "Zimbra connection successful"}
    end
  end

  describe "discover_calendars/2" do
    test "refuses to attempt discovery without credentials" do
      # CaldavCommon checks the credentials before anything reaches the URL
      # guard or the circuit breaker, so a blank password never costs a
      # request against the customer's server.
      client = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "",
        calendar_paths: [],
        provider: :zimbra
      }

      assert Provider.discover_calendars(client) == {:error, :invalid_credentials}
    end

    test "rejects a loopback base_url before issuing a discovery request" do
      # Zimbra's base_url is user-supplied, so discovery runs through the same
      # SSRF guard as every other CalDAV-family provider. Pinning the guard's
      # own message is what proves the guard fired: a bare `{:error, _}` also
      # holds once the guard is removed and the request simply fails instead.
      client = %{
        base_url: "http://localhost:8080",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      assert Provider.discover_calendars(client) ==
               {:error, :private_address}
    end
  end

  # The four delegations below are asserted against a client with no calendar
  # path configured. That is the one point in the chain reached before any
  # request is built, so the message CaldavCommon returns there identifies
  # which shared function the call landed in — without needing a server, and
  # without the assertion quietly passing on any error at all.
  describe "list_events/3" do
    test "delegates a valid time range to CaldavCommon" do
      client = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 86_400, :second)

      assert Provider.list_events(client, start_time: start_time, end_time: end_time) ==
               {:error, "No calendars configured"}
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
    test "delegates to CaldavCommon, which refuses without a target calendar" do
      client = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      event_data = %{
        summary: "Zimbra Meeting",
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
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      event_data = %{
        summary: "Updated Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Provider.update_event(client, "zimbra-event-123", event_data) ==
               {:error, "Event not found"}
    end
  end

  describe "delete_event/3" do
    test "delegates to CaldavCommon, for which deleting from no calendar is a no-op" do
      client = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: [],
        provider: :zimbra
      }

      assert Provider.delete_event(client, "zimbra-event-123", []) == :ok
    end
  end

  describe "setup_component/0" do
    test "returns the CaldavFamilyConfig component module" do
      assert Provider.setup_component() ==
               TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavFamilyConfig
    end
  end
end
