defmodule Tymeslot.Integrations.Calendar.CalDAVLiveIntegrationTest do
  @moduledoc """
  Live round-trip against a real CalDAV server: connect, discover, create,
  fetch, delete.

  ## Why this file is parameterised

  It was written against Baikal and hardcoded Baikal's layout — the
  `/dav.php/...` prefix and the `/dav.php/calendars/{user}/default/`
  collection path. Those paths are one server's convention, not the protocol's,
  so pointing the file at a Radicale container failed three tests: two because
  the collection path does not exist there, and one because it caught a real
  defect in `test_connection/2` (a non-multistatus success was being read as
  proof of authentication).

  The server details now come from the environment, defaulting to the Radicale
  container these tests were last run against. Nothing here is server-specific
  beyond those values, because everything it exercises is RFC 4791/5545:

      CALDAV_TEST_BASE_URL       default http://localhost:8800
      CALDAV_TEST_USERNAME       default testuser
      CALDAV_TEST_PASSWORD       default testpass123
      CALDAV_TEST_CALENDAR_PATH  default /testuser/default/
      CALDAV_TEST_CALENDAR_NAME  default Test Calendar
      CALDAV_TEST_PROVIDER       default radicale

  For a Baikal server, the equivalent is:

      CALDAV_TEST_BASE_URL=http://localhost:8800/dav.php \\
      CALDAV_TEST_CALENDAR_PATH=/dav.php/calendars/testuser/default/ \\
      CALDAV_TEST_PROVIDER=caldav

  ## Absence is a skip, not a failure

  `setup_all` probes the server once and skips the whole module when nothing
  answers. A suite that goes red because a developer does not happen to have a
  container running teaches people to ignore it, which is the same reasoning
  that keeps this module out of CI. A skip says "not measured"; a failure
  should only ever mean "measured, and wrong".

  ## Running it

  Radicale, seeded with a `testuser` collection named "Test Calendar":

      docker compose -f docker/caldav-test/compose.yml up -d

  See `docker/caldav-test/README.md`. Then:

      mix test --only calendar_integration \\
        test/tymeslot/integrations/calendar/caldav_live_integration_test.exs

  ## One implementation, not a family

  Whatever server this runs against is a single CalDAV implementation. A green
  run here is evidence about that server, not about Nextcloud, Fastmail or
  iCloud.
  """
  use ExUnit.Case, async: false

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Calendar.CalDAV.Discovery
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  @base_url System.get_env("CALDAV_TEST_BASE_URL", "http://localhost:8800")
  @username System.get_env("CALDAV_TEST_USERNAME", "testuser")
  @password System.get_env("CALDAV_TEST_PASSWORD", "testpass123")
  @calendar_path System.get_env("CALDAV_TEST_CALENDAR_PATH", "/testuser/default/")
  @calendar_name System.get_env("CALDAV_TEST_CALENDAR_NAME", "Test Calendar")
  @provider String.to_atom(System.get_env("CALDAV_TEST_PROVIDER", "radicale"))

  @client %{
    base_url: @base_url,
    username: @username,
    password: @password,
    calendar_paths: [@calendar_path],
    verify_ssl: false,
    provider: @provider
  }

  # The live container runs on localhost, which the discovery SSRF guard blocks
  # by default (matching the persistence posture). This trusted in-process
  # integration test opts out via `allow_private_ips: true`.
  @local_opts [ip_address: "127.0.0.1", allow_private_ips: true]

  # One TCP probe for the whole module, at compile time, so absence becomes an
  # ExUnit *skip* rather than six failures. `@tag :skip` is the only mechanism
  # ExUnit honours as a skip; a `setup_all` returning a `:skip` key just puts a
  # value in the context and every test still runs — and then fails on the
  # circuit breaker, which is precisely the noise this guard exists to avoid.
  @server_status (
                   uri = URI.parse(@base_url)
                   port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
                   host = String.to_charlist(uri.host || "localhost")

                   case :gen_tcp.connect(host, port, [:binary, active: false], 1_000) do
                     {:ok, socket} ->
                       :gen_tcp.close(socket)
                       :reachable

                     {:error, reason} ->
                       {:unreachable, inspect(reason)}
                   end
                 )

  # Hoisted out of the `case` below: `CredoChecks.TestModuleTagRequired` reads
  # the module body statically and cannot see a tag nested inside a branch, so
  # a tag applied in both arms still reads as absent.
  @moduletag :calendar_integration
  @moduletag :calendar
  @moduletag :integrations

  case @server_status do
    :reachable ->
      :ok

    {:unreachable, reason} ->
      @moduletag skip: "no CalDAV server at #{@base_url} (#{reason}) — see @moduledoc"
  end

  setup do
    # Use the real HTTP client (not the Mox mock that's the default in test
    # mode) and route requests through Finch (not the Req.Test plug).
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, nil)
    :ok
  end

  describe "test_connection/2" do
    test "succeeds with correct credentials" do
      assert {:ok, message} = Discovery.test_connection(@client, @local_opts)
      assert byte_size(message) > 0
    end

    test "returns :unauthorized for wrong password" do
      # The regression this file caught: a server answering the guessed
      # discovery path with anything other than a 207 has not proved the
      # credentials, and reporting success here tells an organiser their
      # password works while every later sync fails.
      bad_client = %{@client | password: "wrongpassword"}

      assert {:error, :unauthorized} = Discovery.test_connection(bad_client, @local_opts)
    end
  end

  describe "discover_calendars/2" do
    test "discovers the configured calendar" do
      assert {:ok, calendars} = CaldavCommon.discover_calendars(@client, @local_opts)
      assert calendars != []

      calendar_names = Enum.map(calendars, & &1.name)

      assert @calendar_name in calendar_names,
             "Expected #{inspect(@calendar_name)} in #{inspect(calendar_names)}"
    end

    test "each calendar has required fields" do
      assert {:ok, calendars} = CaldavCommon.discover_calendars(@client, @local_opts)

      # A green check over an empty list measures nothing.
      assert calendars != []

      Enum.each(calendars, fn cal ->
        assert byte_size(cal.name) > 0
        assert byte_size(cal.path) > 0
        assert byte_size(cal.id) > 0
      end)
    end
  end

  describe "event round-trip" do
    test "creates an event and fetches it back" do
      uid = unique_uid("caldav-create")
      now = DateTime.utc_now()

      # CalDAV creates return {:ok, uid} — a bare string, not a map.
      assert {:ok, _uid} = CaldavCommon.put_raw_event(@client, uid, ical_for(uid, now))

      assert {:ok, events} =
               CaldavCommon.get_events(@client, now, DateTime.add(now, 10_800, :second))

      event_uids = Enum.map(events, & &1.uid)

      assert full_uid(uid) in event_uids,
             "Newly created event UID not found in fetched events: #{inspect(event_uids)}"
    end

    test "deletes an event" do
      uid = unique_uid("caldav-delete")
      now = DateTime.utc_now()

      assert {:ok, _uid} = CaldavCommon.put_raw_event(@client, uid, ical_for(uid, now))
      assert :ok = CaldavCommon.delete_event(@client, uid)

      assert {:ok, events} =
               CaldavCommon.get_events(@client, now, DateTime.add(now, 10_800, :second))

      refute full_uid(uid) in Enum.map(events, & &1.uid),
             "Deleted event still appeared in fetched events"
    end
  end

  # Helpers

  defp unique_uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp full_uid(uid), do: "#{uid}@caldav-integration-test"

  defp ical_for(uid, now) do
    start_dt = now |> DateTime.add(3600, :second) |> format_ical_dt()
    end_dt = now |> DateTime.add(7200, :second) |> format_ical_dt()

    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Tymeslot//CalDAVLiveIntegrationTest//EN
    BEGIN:VEVENT
    UID:#{full_uid(uid)}
    DTSTAMP:#{format_ical_dt(now)}
    DTSTART:#{start_dt}
    DTEND:#{end_dt}
    SUMMARY:CalDAV Integration Test Event
    DESCRIPTION:Created by Tymeslot CalDAV integration test
    END:VEVENT
    END:VCALENDAR
    """
  end

  # Format a DateTime as an iCalendar UTC datetime string (e.g. 20260513T100000Z).
  defp format_ical_dt(%DateTime{} = dt) do
    dt = DateTime.truncate(dt, :second)

    to_string(
      :io_lib.format(
        "~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ",
        [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
      )
    )
  end
end
