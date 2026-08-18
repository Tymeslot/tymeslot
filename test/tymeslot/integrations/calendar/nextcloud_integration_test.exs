defmodule Tymeslot.Integrations.Calendar.NextcloudIntegrationTest do
  @moduledoc """
  Live integration test against Nextcloud (Docker), covering CalDAV discovery
  from every base URL shape a user realistically supplies.

  Discovery is the one CalDAV surface `mix calendar_audit` cannot reach: it
  probes connectivity against already-stored `calendar_paths`, so a bug in
  building the *discovery* URL is invisible to it. That gap is why a broken
  discovery path could ship, and why this file exercises `Provider.new/1`
  (the normalisation) followed by a real PROPFIND (the request it produces).

  Requires two containers, a root install and a subdirectory install:

      docker run -d --name tymeslot-nc -p 8080:80 \\
        -e SQLITE_DATABASE=nextcloud \\
        -e NEXTCLOUD_ADMIN_USER=alice \\
        -e NEXTCLOUD_ADMIN_PASSWORD=alicepassword123 \\
        -e NEXTCLOUD_TRUSTED_DOMAINS="localhost 127.0.0.1" \\
        nextcloud:31-apache

      docker run -d --name tymeslot-nc-sub --network tymeslot-nc-net \\
        -e OVERWRITEWEBROOT=/nextcloud ... nextcloud:31-apache
      # fronted by nginx on :8081 stripping the /nextcloud prefix

  Run with:
      mix test test/tymeslot/integrations/calendar/nextcloud_integration_test.exs --include calendar_integration
  """
  use ExUnit.Case, async: false
  @moduletag :calendar_integration
  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder
  alias Tymeslot.Integrations.Calendar.Nextcloud.Provider, as: NextcloudProvider
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  @username "alice"
  @password "alicepassword123"

  @root "http://localhost:8080"
  @sub "http://localhost:8081/nextcloud"

  setup do
    # Test mode defaults `:http_client_module` to a Mox mock and routes Req
    # through a test plug; a live server needs the real client on both counts.
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, nil)

    # Discovery runs behind the calendar circuit breaker, which opens after a
    # few consecutive failures against a host and then rejects everything with
    # `:circuit_open`. Without a reset per case, one genuinely broken URL shape
    # cascades into spurious failures for every shape that runs after it, and
    # the suite's result depends on the seed rather than on the code.
    CalendarCircuitBreaker.reset(:nextcloud)
    CalendarCircuitBreaker.reset_all_hosts()
    :ok
  end

  # Nextcloud runs on loopback here, which the discovery SSRF guard blocks by
  # default. This trusted in-process test opts out, as the Baikal suite does.
  @local_opts [ip_address: "127.0.0.1", allow_private_ips: true]

  defp client(base_url) do
    NextcloudProvider.new(%{
      base_url: base_url,
      username: @username,
      password: @password
    })
  end

  defp discover(base_url) do
    base_url |> client() |> CaldavCommon.discover_calendars(@local_opts)
  end

  # Every shape below is a URL a user can plausibly paste into the Nextcloud
  # setup form: the instance root, the DAV endpoint, a full calendar URL, and
  # the browser locations they copy out of a running Nextcloud tab.
  @root_inputs [
    {"instance root", @root},
    {"instance root with trailing slash", @root <> "/"},
    {"DAV endpoint", @root <> "/remote.php/dav"},
    {"DAV endpoint with trailing slash", @root <> "/remote.php/dav/"},
    {"full calendar URL", @root <> "/remote.php/dav/calendars/alice/"},
    {"browser paste: index.php app route",
     @root <> "/index.php/apps/calendar/dayGridMonth/2026-04-20"},
    {"browser paste: app route", @root <> "/apps/calendar/"},
    {"browser paste: settings", @root <> "/index.php/settings/user"}
  ]

  # The same shapes against a subdirectory install. These are the regressions
  # the discovery fix exists for: the old normalisation reduced them to
  # `scheme://host`, discarding `/nextcloud` entirely.
  @sub_inputs [
    {"subdirectory root", @sub},
    {"subdirectory root with trailing slash", @sub <> "/"},
    {"subdirectory DAV endpoint", @sub <> "/remote.php/dav"},
    {"subdirectory full calendar URL", @sub <> "/remote.php/dav/calendars/alice/"},
    {"subdirectory browser paste: index.php app route",
     @sub <> "/index.php/apps/calendar/dayGridMonth/2026-04-20"},
    {"subdirectory browser paste: app route", @sub <> "/apps/calendar/"}
  ]

  describe "discovery against a root Nextcloud install" do
    for {label, input} <- @root_inputs do
      test "discovers calendars from #{label}" do
        assert {:ok, calendars} = discover(unquote(input)),
               "discovery failed for #{unquote(input)} " <>
                 "(discovery URL: #{UrlBuilder.build_discovery_url(client(unquote(input)))})"

        assert calendars != [], "no calendars discovered for #{unquote(input)}"

        Enum.each(calendars, fn cal ->
          assert byte_size(cal.name) > 0
          assert byte_size(cal.path) > 0
          assert byte_size(cal.id) > 0
        end)
      end
    end

    test "builds the discovery URL under the DAV service root" do
      assert UrlBuilder.build_discovery_url(client(@root)) ==
               "#{@root}/remote.php/dav/calendars/#{@username}/"
    end
  end

  describe "discovery against a subdirectory Nextcloud install" do
    for {label, input} <- @sub_inputs do
      test "discovers calendars from #{label}" do
        assert {:ok, calendars} = discover(unquote(input)),
               "discovery failed for #{unquote(input)} " <>
                 "(discovery URL: #{UrlBuilder.build_discovery_url(client(unquote(input)))})"

        assert calendars != [], "no calendars discovered for #{unquote(input)}"
      end
    end

    test "keeps the subdirectory in the discovery URL" do
      assert UrlBuilder.build_discovery_url(client(@sub)) ==
               "#{@sub}/remote.php/dav/calendars/#{@username}/"
    end
  end

  # Discovery succeeding proves only that the calendars can be *listed*. The
  # paths it returns then go back through `Provider.new/1` on every sync,
  # booking conflict check and event write, and a subdirectory install's href
  # used to be mangled there — so discovery passed while everything downstream
  # queried an address the server does not serve. Exercising a real REPORT
  # against a discovered path is what closes that gap; a discovery-only suite
  # cannot see it.
  describe "using a discovered calendar" do
    for {label, input} <- [{"root install", @root}, {"subdirectory install", @sub}] do
      test "fetches events from a calendar discovered on a #{label}" do
        assert {:ok, calendars} = discover(unquote(input))

        collections = Enum.reject(calendars, &(&1.path in [nil, ""]))
        assert collections != [], "discovery returned no usable calendar paths"

        {:ok, window_start} = DateTime.new(~D[2026-01-01], ~T[00:00:00], "Etc/UTC")
        {:ok, window_end} = DateTime.new(~D[2026-12-31], ~T[23:59:59], "Etc/UTC")

        failures =
          Enum.reject(collections, fn calendar ->
            client =
              NextcloudProvider.new(%{
                base_url: unquote(input),
                username: @username,
                password: @password,
                calendar_paths: [calendar.path]
              })

            match?({:ok, _events}, CaldavCommon.get_events(client, window_start, window_end))
          end)

        assert failures == [],
               "REPORT failed for: " <>
                 Enum.map_join(failures, ", ", fn calendar ->
                   client =
                     NextcloudProvider.new(%{
                       base_url: unquote(input),
                       username: @username,
                       password: @password,
                       calendar_paths: [calendar.path]
                     })

                   UrlBuilder.build_calendar_url(client.base_url, hd(client.calendar_paths))
                 end)
      end
    end
  end

  describe "credential handling" do
    test "returns :unauthorized for a wrong password" do
      bad = %{client(@root) | password: "wrongpassword"}

      assert {:error, :unauthorized} = CaldavCommon.discover_calendars(bad, @local_opts)
    end
  end
end
