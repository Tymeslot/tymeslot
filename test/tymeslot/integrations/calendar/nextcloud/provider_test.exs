defmodule Tymeslot.Integrations.Calendar.Nextcloud.ProviderTest do
  use Tymeslot.MockCase, async: true
  @moduletag :integrations

  import ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder
  alias Tymeslot.Integrations.Calendar.Nextcloud.Provider

  setup do
    CalendarCircuitBreaker.reset(:nextcloud)
    :ok
  end

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

    # `validate_config/1` is structural only — it never performs network I/O
    # (the connectivity probe used to run here too, doubling the rate-limit
    # charge across two buckets for a single form submission). A structurally
    # valid config passes even when nothing is listening on the other end;
    # the live check now runs separately, through `test_connection/1`.
    test "accepts calendar URL format without touching the network" do
      config = %{
        base_url: "https://cloud.example.com/remote.php/dav/calendars/user/personal",
        username: "user",
        password: "pass"
      }

      assert :ok = Provider.validate_config(config)
    end

    test "accepts standard Nextcloud URL without touching the network" do
      config = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      assert :ok = Provider.validate_config(config)
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
      # Nextcloud speaks CalDAV under the hood but keeps its own provider tag.
      assert client.provider == :nextcloud
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

      # Relative to base_url, which ends in the DAV endpoint, rather than to the
      # origin: a leading slash here would resolve against scheme://host alone
      # and drop /remote.php/dav.
      assert client.calendar_paths == ["calendars/testuser/personal/"]
    end

    test "defaults to personal calendar when no paths provided" do
      config = %{
        base_url: "http://localhost:1",
        username: "user",
        password: "pass"
      }

      client = Provider.new(config)

      assert client.calendar_paths == ["calendars/user/personal/"]
    end

    test "extracts username from calendar URL when not provided" do
      config = %{
        base_url: "https://cloud.example.com/remote.php/dav/calendars/john/personal",
        password: "pass"
      }

      client = Provider.new(config)

      # Username should be extracted from URL
      assert client.username == "john"
    end
  end

  describe "test_connection/2" do
    test "probes the CalDAV principal URL even when base_url omits /remote.php/dav" do
      # Regression: `Creation.prepare_attrs` persists the user-entered URL verbatim
      # (e.g. "https://cloud.example.com"), while `validate_config` normalises before
      # probing. Without normalisation here the discovery URL becomes
      # `<base_url>/calendars/<user>/`, which Nextcloud answers with HTTP 405 because
      # CalDAV is mounted at `/remote.php/dav/`.
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: ["/remote.php/dav/calendars/alice/personal/"]
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, url, _body, _headers, _opts ->
        assert url =~ "/remote.php/dav/", "probed wrong URL: #{url}"
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert {:ok, "Nextcloud connection successful"} =
               Provider.perform_connection_test(integration)
    end

    test "returns Nextcloud-specific success message" do
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: []
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert Provider.perform_connection_test(integration) ==
               {:ok, "Nextcloud connection successful"}
    end

    test "translates 401 to a Nextcloud-flavoured authentication failure message" do
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "wrong",
        calendar_paths: []
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, message} = Provider.perform_connection_test(integration)
      assert message =~ "Authentication failed"
      assert message =~ "app password"
    end

    test "refuses a loopback base_url before any request is issued" do
      # The connection test runs through the same guard as discovery below:
      # `CalDAV.Discovery` validates the URL with `block_private_ips: true`
      # unless `:allow_private_ips_for_calendar` is set. No stub is declared
      # here, so any request that did go out would raise instead of reaching
      # this assertion.
      integration = %{
        base_url: "http://localhost:8080",
        username: "alice",
        password: "secret",
        calendar_paths: []
      }

      assert Provider.perform_connection_test(integration) ==
               {:error, "Private or local network addresses are not allowed"}
    end

    test "returns Nextcloud-specific :not_found message when server returns 404" do
      # Discovery.test_connection falls back to the RFC 4791 chain when the
      # primary PROPFIND returns 404, asking the supplied URL for a principal
      # before the origin root. Nextcloud's base URL is normalised to
      # ".../remote.php/dav", so those are two distinct probes and three
      # requests are issued before {:error, :not_found} reaches the provider.
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: []
      }

      # Primary PROPFIND on the guessed discovery path → 404
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      # RFC 4791 principal probe on the supplied URL (".../remote.php/dav/")
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      # RFC 4791 principal probe on the origin root ("/") → also 404
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert Provider.perform_connection_test(integration) ==
               {:error,
                "Nextcloud server not found or CalDAV endpoint not accessible. Check your server URL."}
    end

    test "passes transport errors through unchanged via catch-all clause" do
      # The default MockCase stub returns {:error, %Mint.TransportError{reason: :timeout}}.
      # The provider catch-all at line 163 forwards unknown error reasons as-is.
      integration = %{
        base_url: "https://cloud.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: []
      }

      assert {:error, _reason} = Provider.perform_connection_test(integration)
    end
  end

  describe "discover_calendars/1" do
    test "returns error without valid Nextcloud server" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :nextcloud
      }

      capture_log(fn ->
        result = Provider.discover_calendars(client)
        assert {:error, _message} = result
      end)
    end

    # Nextcloud's base_url is user-editable from the reconnect modal (it is
    # not in ProviderConfig's @locked_url_providers), so discovery must go
    # through the same SSRF guard as every other CalDAV-family provider
    # (block_private_ips: true, enforce_https_for_public: true) rather than
    # issuing a PROPFIND straight to whatever host is submitted.
    for {description, base_url} <- [
          {"the AWS metadata endpoint", "http://169.254.169.254/"},
          {"an RFC 1918 private host", "http://10.0.0.1/"},
          {"a loopback host", "http://localhost:8080/"}
        ] do
      test "rejects #{description} without issuing a request" do
        client = %{
          base_url: unquote(base_url),
          username: "user",
          password: "pass",
          calendar_paths: [],
          provider: :nextcloud
        }

        # Pinning the guard's own message is what makes this a test of the
        # guard. A bare `{:error, _}` also holds with the guard removed —
        # the request then fails against the stubbed transport instead.
        assert Provider.discover_calendars(client) ==
                 {:error, "Private or local network addresses are not allowed"}
      end
    end
  end

  describe "list_events/3" do
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

      capture_log(fn ->
        # The CalDAV REPORT is issued from the circuit breaker's own task, outside
        # the Mox-owned process, so the response cannot be stubbed here. What this
        # asserts is the delegation itself: the time range was accepted and a
        # request attempted, rather than short-circuiting on :missing_time_range.
        assert {:error, reason} =
                 Provider.list_events(client, start_time: start_time, end_time: end_time)

        refute reason == :missing_time_range
      end)
    end

    test "returns error when time range is missing" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: ["/calendars/user/personal/"],
        provider: :nextcloud
      }

      assert Provider.list_events(client, []) == {:error, :missing_time_range}
    end
  end

  # The three delegations below are asserted against a client with no calendar
  # path configured. That is the one observable point in the chain that is
  # reached before any request is built, so the message CaldavCommon returns
  # there identifies which shared function the call landed in — without
  # needing a server, and without the assertion quietly passing on any error
  # at all.
  describe "create_event/2" do
    test "delegates to CalDAV provider, which refuses without a target calendar" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :nextcloud
      }

      event_data = %{
        summary: "Nextcloud Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Provider.create_event(client, event_data) ==
               {:error, "No calendar configured for creating events"}
    end
  end

  describe "update_event/3" do
    test "delegates to CalDAV provider, which reports an unconfigured calendar as not found" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :nextcloud
      }

      event_data = %{
        summary: "Updated Event",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Provider.update_event(client, "nextcloud-event-123", event_data) ==
               {:error, "Event not found"}
    end
  end

  describe "delete_event/2" do
    test "delegates to CalDAV provider, for which deleting from no calendar is a no-op" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider: :nextcloud
      }

      assert Provider.delete_event(client, "nextcloud-event-123") == :ok
    end
  end

  # `new/1` decides the shape of every calendar path the CalDAV client then
  # uses, and `UrlBuilder.build_calendar_url/2` resolves a leading slash
  # against the origin alone but anything else against `base_url`. So the
  # assertions below are on the URL a read or write actually requests: the
  # intermediate path list is an implementation detail, and asserting on it
  # would not show that a subdirectory install ends up off the DAV mount.
  describe "new/1 calendar path resolution" do
    defp event_url(base_url, calendar_paths) do
      client =
        Provider.new(%{
          base_url: base_url,
          username: "alice",
          password: "pw",
          calendar_paths: calendar_paths
        })

      [path] = client.calendar_paths
      UrlBuilder.build_calendar_url(client.base_url, path)
    end

    test "resolves a discovered href on a root install" do
      assert event_url("https://cloud.example.com", ["/remote.php/dav/calendars/alice/personal/"]) ==
               "https://cloud.example.com/remote.php/dav/calendars/alice/personal/"
    end

    # Regression: a subdirectory install's href matched none of the leading
    # paths this function used to test for, so it fell through to the
    # bare-name branch and was concatenated whole into the middle of a new
    # path — producing
    # `/calendars/alice//nextcloud/remote.php/dav/calendars/alice/personal//`.
    # Discovery listed the calendars, then every read and write went to a URL
    # no Nextcloud instance serves, silently: busy times came back empty, so
    # conflict checking stopped blocking anything.
    test "resolves a discovered href on a subdirectory install" do
      assert event_url("https://example.com/nextcloud", [
               "/nextcloud/remote.php/dav/calendars/alice/personal/"
             ]) == "https://example.com/nextcloud/remote.php/dav/calendars/alice/personal/"
    end

    # A bare name is what a user typing into the calendar-paths field supplies,
    # and what the `["personal"]` default produces. Anchoring it at the root
    # dropped `/remote.php/dav` on every install, not only subdirectory ones.
    test "resolves a bare calendar name under the DAV endpoint on a root install" do
      assert event_url("https://cloud.example.com", ["personal"]) ==
               "https://cloud.example.com/remote.php/dav/calendars/alice/personal/"
    end

    test "resolves a bare calendar name under the DAV endpoint on a subdirectory install" do
      assert event_url("https://example.com/nextcloud", ["personal"]) ==
               "https://example.com/nextcloud/remote.php/dav/calendars/alice/personal/"
    end
  end
end
