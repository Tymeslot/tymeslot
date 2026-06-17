defmodule Tymeslot.Integrations.Calendar.BaikalIntegrationTest do
  @moduledoc """
  Live integration test against a Baikal CalDAV server (Docker, port 8800).

  Requires the Baikal container to be running:
    docker run -d --name baikal-test -p 8800:80 ckulka/baikal:latest

  Run with:
    mix test apps/tymeslot/test/tymeslot/integrations/calendar/baikal_integration_test.exs
  """
  use ExUnit.Case, async: false
  @moduletag :calendar_integration

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Calendar.CalDAV.Discovery
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  @baikal_base_url "http://localhost:8800/dav.php"
  @baikal_username "testuser"
  @baikal_password "testpass123"
  @baikal_calendar_path "/dav.php/calendars/testuser/default/"

  @client %{
    base_url: @baikal_base_url,
    username: @baikal_username,
    password: @baikal_password,
    calendar_paths: [@baikal_calendar_path],
    verify_ssl: false,
    provider: :caldav
  }

  setup do
    # Use the real HTTP client (not the Mox mock that's the default in test mode)
    # and route requests through Finch (not Req.Test plug)
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, nil)
    :ok
  end

  # The live Baikal container runs on localhost, which the discovery SSRF guard
  # blocks by default (matching the persistence posture). This trusted in-process
  # integration test opts out via `allow_private_ips: true`.
  @local_opts [ip_address: "127.0.0.1", allow_private_ips: true]

  describe "test_connection/2 against Baikal" do
    test "successfully connects to Baikal" do
      assert {:ok, message} = Discovery.test_connection(@client, @local_opts)
      assert is_binary(message)
    end

    test "returns :unauthorized for wrong password" do
      bad_client = %{@client | password: "wrongpassword"}

      assert {:error, :unauthorized} =
               Discovery.test_connection(bad_client, @local_opts)
    end
  end

  describe "discover_calendars/2 against Baikal" do
    test "discovers the Test Calendar" do
      assert {:ok, calendars} = CaldavCommon.discover_calendars(@client, @local_opts)
      assert calendars != []

      calendar_names = Enum.map(calendars, & &1.name)

      assert "Test Calendar" in calendar_names,
             "Expected 'Test Calendar' in #{inspect(calendar_names)}"
    end

    test "each calendar has required fields" do
      assert {:ok, calendars} = CaldavCommon.discover_calendars(@client, @local_opts)

      Enum.each(calendars, fn cal ->
        assert is_binary(cal.name)
        assert is_binary(cal.href)
        assert is_binary(cal.id)
      end)
    end
  end

  describe "event round-trip against Baikal" do
    test "creates an event and fetches it back" do
      uid = "baikal-test-#{System.unique_integer([:positive])}"

      now = DateTime.utc_now()
      start_dt = now |> DateTime.add(3600, :second) |> format_ical_dt()
      end_dt = now |> DateTime.add(7200, :second) |> format_ical_dt()

      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Tymeslot//BaikalIntegrationTest//EN
      BEGIN:VEVENT
      UID:#{uid}@baikal-integration-test
      DTSTAMP:#{format_ical_dt(now)}
      DTSTART:#{start_dt}
      DTEND:#{end_dt}
      SUMMARY:Baikal Integration Test Event
      DESCRIPTION:Created by Tymeslot CalDAV integration test
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, _result} = CaldavCommon.put_raw_event(@client, uid, ical)

      # Fetch events for today + next 3 hours window
      range_start = now
      range_end = DateTime.add(now, 10_800, :second)

      assert {:ok, events} = CaldavCommon.get_events(@client, range_start, range_end)
      event_uids = Enum.map(events, fn e -> e.uid end)

      assert "#{uid}@baikal-integration-test" in event_uids,
             "Newly created event UID not found in fetched events: #{inspect(event_uids)}"
    end

    test "deletes an event" do
      uid = "baikal-delete-#{System.unique_integer([:positive])}"

      now = DateTime.utc_now()
      start_dt = now |> DateTime.add(3600, :second) |> format_ical_dt()
      end_dt = now |> DateTime.add(7200, :second) |> format_ical_dt()

      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Tymeslot//BaikalIntegrationTest//EN
      BEGIN:VEVENT
      UID:#{uid}@baikal-integration-test
      DTSTAMP:#{format_ical_dt(now)}
      DTSTART:#{start_dt}
      DTEND:#{end_dt}
      SUMMARY:Baikal Delete Test
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, _result} = CaldavCommon.put_raw_event(@client, uid, ical)
      assert :ok = CaldavCommon.delete_event(@client, uid)

      range_start = now
      range_end = DateTime.add(now, 10_800, :second)
      {:ok, events} = CaldavCommon.get_events(@client, range_start, range_end)

      event_uids = Enum.map(events, fn e -> e.uid end)

      refute "#{uid}@baikal-integration-test" in event_uids,
             "Deleted event still appeared in fetched events"
    end
  end

  # Format a DateTime as iCalendar UTC datetime string (e.g. 20260513T100000Z)
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
