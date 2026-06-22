defmodule Tymeslot.Integrations.Calendar.CalDAV.HttpSsrfTest do
  @moduledoc """
  Verifies that every call site in `CalDAV.Http` passes `ssrf_protect: true`
  to the HTTP client.

  Each test pins the environment to `:prod` (the condition under which the SSRF
  guard is active) and injects a DNS resolver that always returns a private
  address.  Removing `ssrf_protect: true` from any call site would allow the
  request to reach the Req.Test stub, which calls `flunk/1` — making that test
  fail.

  Tests cover: propfind, report (read path) and put_event, delete_event,
  head_event (write/HEAD path).
  """

  use Tymeslot.CalDAVCase, async: false

  @moduletag :integrations
  @moduletag :security

  alias Tymeslot.Integrations.Calendar.CalDAV.Http

  setup do
    with_config(:tymeslot, :environment, :prod)
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    with_config(:tymeslot, :dns_resolver_module, CalDAVSsrfPrivateResolver)
    :ok
  end

  describe "propfind/4 call site threads ssrf_protect: true" do
    test "blocks the request when the CalDAV host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the CalDAV server — ssrf_protect: true is missing")
      end)

      # SsrfBlockedError is not a timeout/transport error so handle_propfind_error
      # maps it to :network_error.
      assert {:error, :network_error} =
               Http.propfind(
                 "https://internal-caldav.corp/calendars/user/",
                 "user",
                 "pass",
                 max_retries: 0
               )
    end
  end

  describe "report/5 call site threads ssrf_protect: true" do
    test "blocks the request when the CalDAV host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the CalDAV server — ssrf_protect: true is missing")
      end)

      assert {:error, :network_error} =
               Http.report(
                 "https://internal-caldav.corp/calendars/user/personal/",
                 "user",
                 "pass",
                 "<calendar-query/>"
               )
    end
  end

  describe "put_event/5 call site threads ssrf_protect: true" do
    test "blocks the request when the CalDAV host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the CalDAV server — ssrf_protect: true is missing")
      end)

      # SsrfBlockedError is not a timeout error so handle_write_network_error
      # maps it to :network_error.
      assert {:error, :network_error} =
               Http.put_event(
                 "https://internal-caldav.corp/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR"
               )
    end
  end

  describe "delete_event/4 call site threads ssrf_protect: true" do
    test "blocks the request when the CalDAV host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the CalDAV server — ssrf_protect: true is missing")
      end)

      assert {:error, :network_error} =
               Http.delete_event(
                 "https://internal-caldav.corp/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end
  end

  describe "head_event/4 call site threads ssrf_protect: true" do
    test "blocks the request when the CalDAV host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the CalDAV server — ssrf_protect: true is missing")
      end)

      assert {:error, :network_error} =
               Http.head_event(
                 "https://internal-caldav.corp/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end
  end
end

defmodule CalDAVSsrfPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end
