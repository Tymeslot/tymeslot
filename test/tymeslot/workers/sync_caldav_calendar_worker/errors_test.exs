defmodule Tymeslot.Workers.SyncCalDavCalendarWorker.ErrorsTest do
  @moduledoc """
  Covers the CalDAV sync worker's error handling: provider authentication
  failures (401), missing calendar paths (404), refused requests (415 and 405),
  sync-token expiry (410), the deletion circuit breaker, and a delta the
  server answered without any event data.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.CalDAVSyncTestFixtures
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    :ok
  end

  describe "perform/1 - auth failures" do
    test "returns :ok without retrying when CalDAV server returns 401" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1()]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "Unauthorized")
      end)

      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "reauthentication"
    end
  end

  describe "perform/1 - calendar path no longer exists (HTTP 404)" do
    test "flags the integration for reconnection and discards when the booking path is gone" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1()]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 404, "Not Found")
      end)

      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "not found"

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert updated.needs_reauth == true
      assert updated.sync_error =~ "no longer exists"
    end

    test "flags the integration when the booking path is gone during Tier 1 delta sync" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path1()],
          caldav_sync_token: "valid-sync-token"
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 404, "Not Found")
      end)

      assert {:discard, _reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert updated.needs_reauth == true
    end

    test "removes an extra path that is gone and completes the sync" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1(), path2()]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        if conn.request_path == path1() do
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, caldav_report_xml("#{path1()}event1.ics", ical_path1()))
        else
          Conn.send_resp(conn, 404, "Not Found")
        end
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert updated.calendar_paths == [path1()]
      assert updated.needs_reauth == false
    end
  end

  describe "perform/1 - the server refuses the request" do
    test "discards on a 4xx the transport layer does not model" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1()]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 415, "Unsupported Media Type")
      end)

      # Retrying re-sends the same bytes for the same refusal, so the job must
      # not burn its remaining attempts and raise an admin alert on the last.
      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "HTTP 415"

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      # The refusal says nothing about the credentials, so it must not push the
      # user through a reconnection they do not need.
      assert updated.needs_reauth == false
    end

    test "discards a 405 without treating the calendar as gone" do
      # 405 is modelled as `:method_not_allowed` so discovery can fall back on
      # it. Two things must survive that: it stays terminal here (a retryable
      # 405 re-sends the same bytes for the same refusal three times, then
      # raises a permanent-failure admin alert nobody can act on), and it never
      # behaves like `:not_found`, which deletes calendar paths and pushes the
      # owner through a reconnection they do not need.
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1(), path2()]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 405, "Method Not Allowed")
      end)

      assert {:discard, _reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert updated.calendar_paths == [path1(), path2()]
      assert updated.needs_reauth == false
    end

    test "discards a 5xx and leaves the retry to the next scheduled sync" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1()]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 503, "Service Unavailable")
      end)

      # The remote is broken, not the request — but the three Oban attempts
      # span under a minute, far too short for a server to recover, while the
      # scheduled sync comes round again in minutes. A server that 5xxs
      # persistently used to exhaust the retries every cycle and raise a
      # permanent-failure admin alert each time.
      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "server error"

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      # A remote outage says nothing about the credentials, so it must not push
      # the user through a reconnection they do not need.
      assert updated.needs_reauth == false
    end
  end

  describe "perform/1 - sync token expiry" do
    test "410 clears the stale token and falls back to a full fetch" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path1()],
          caldav_sync_token: "stale-sync-token"
        )

      # The server no longer recognises the stored token, so it answers the
      # sync-collection REPORT with 410 and serves the calendar-query REPORT
      # the worker falls back to.
      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        if body =~ "sync-collection" do
          Conn.send_resp(conn, 410, "Gone")
        else
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, caldav_report_xml("#{path1()}event1.ics", ical_path1()))
        end
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert updated.caldav_sync_token == nil

      assert {:ok, _event} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "event-from-path1@test")
    end

    test "sends the sync-collection REPORT with Depth: 0 as RFC 6578 requires" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path1()],
          caldav_sync_token: "known-token"
        )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        if body =~ "sync-collection" do
          send(test_pid, {:depth, Conn.get_req_header(conn, "depth")})
        end

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{path1()}event1.ics", ical_path1()))
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_received {:depth, ["0"]}
    end
  end

  describe "perform/1 - deletion circuit breaker" do
    @empty_multistatus """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    </D:multistatus>
    """

    test "discards without retrying when the circuit breaker refuses a bulk deletion" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1()]
        )

      # Confirmed an hour ago, so the refusal is still inside the grace period.
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "cached@test",
        provider: "caldav",
        provider_calendar_id: path1(),
        provider_event_id: "#{path1()}cached.ics",
        start_at: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:microsecond),
        end_at: DateTime.utc_now() |> DateTime.add(31, :day) |> DateTime.truncate(:microsecond),
        synced_at:
          DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:microsecond)
      )

      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, @empty_multistatus)
      end)

      # Retrying re-fetches the same empty listing and refuses identically, so
      # the job must not burn its remaining attempts or raise an admin alert.
      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "circuit breaker"

      # The cache survived and the sync token was not advanced.
      assert {:ok, _event} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "cached@test")
    end
  end

  describe "perform/1 - sync-collection returned without event data" do
    test "an etag-only delta falls back to a full fetch instead of cancelling the meetings it names" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path1()],
          caldav_sync_token: "known-token"
        )

      href = "#{path1()}event1.ics"

      # Booked at the time `ical_path1/0` reports, so the fallback full fetch
      # finds the meeting unchanged and every status below stays untouched.
      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: href,
          status: "confirmed",
          start_time: ~U[2099-12-15 10:00:00Z],
          end_time: ~U[2099-12-15 11:00:00Z]
        )

      # A strict server names the changed resource and its etag but declines
      # to inline the calendar data. Reading that as a deletion would cancel
      # the booking this href belongs to and email both parties.
      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        if body =~ "sync-collection" do
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, sync_collection_etag_only_xml(href, "new-token"))
        else
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, caldav_report_xml(href, ical_path1()))
        end
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      reloaded = Repo.get!(Tymeslot.Meetings.MeetingSchema, meeting.id)
      assert reloaded.status == "confirmed"
      assert is_nil(reloaded.calendar_sync_status)

      # The full fetch the worker fell back to is what actually refreshed the
      # calendar, and the token stayed valid so the same delta is offered again.
      assert {:ok, _event} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "event-from-path1@test")

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert updated.caldav_sync_token == "known-token"
    end
  end
end
