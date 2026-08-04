defmodule Tymeslot.Integrations.Calendar.Ics.FeedSsrfTest do
  @moduledoc """
  Covers the SSRF-blocked and transport-failure branches of
  `Feed.fetch_events/2`'s `fetch_body/3`, which `FeedTest` deliberately
  leaves to this module.

  Mirrors `Tymeslot.Integrations.Calendar.CalDAV.HttpSsrfTest`: the blocking
  tests pin the environment to `:prod` (the condition under which
  `SsrfGuard` is active) and inject a DNS resolver so both a literal
  private/link-local target and a public-looking host that resolves to one
  are exercised without any disallowed network access.
  """

  use Tymeslot.CalDAVCase, async: false

  @moduletag :integrations
  @moduletag :security

  alias Tymeslot.Integrations.Calendar.Ics.Feed

  describe "fetch_events/2 SSRF blocking" do
    setup do
      with_config(:tymeslot, :environment, :prod)
      with_config(:tymeslot, :allow_private_ips_for_calendar, false)
      :ok
    end

    test "blocks a link-local target without making a request" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the feed host — SSRF guard was bypassed")
      end)

      assert {:error, {:blocked, _reason}} =
               Feed.fetch_events("http://169.254.169.254/feed.ics")
    end

    test "blocks a private-network target without making a request" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the feed host — SSRF guard was bypassed")
      end)

      assert {:error, {:blocked, _reason}} = Feed.fetch_events("http://10.0.0.5/cal.ics")
    end

    test "blocks a public host whose DNS resolves to a private address" do
      with_config(:tymeslot, :dns_resolver_module, IcsFeedSsrfPrivateResolver)

      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the feed host — SSRF guard was bypassed")
      end)

      assert {:error, {:blocked, _reason}} =
               Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end

    test "refuses a redirect from a public host to an internal address on the hop" do
      with_config(:tymeslot, :dns_resolver_module, IcsFeedSsrfPermissiveResolver)

      stub_sequential(
        fn conn ->
          conn
          |> Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
          |> Conn.send_resp(302, "")
        end,
        fn _conn ->
          flunk("redirect target must be re-validated — it must never reach the internal host")
        end
      )

      assert {:error, {:blocked, _reason}} =
               Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end
  end

  describe "fetch_events/2 transport failure" do
    test "reports a connection failure as a transport error" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        ReqTest.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transport, _reason}} =
               Feed.fetch_events("https://feeds.example.com/calendar.ics")
    end
  end
end

defmodule IcsFeedSsrfPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end

defmodule IcsFeedSsrfPermissiveResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts), do: :ok
end
