defmodule Tymeslot.Workers.SyncCalDavCalendarWorker.ErrorsTest do
  @moduledoc """
  Covers the CalDAV sync worker's error handling: provider authentication
  failures (401) and sync-token expiry (410) responses.
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

  describe "perform/1 - sync token expiry" do
    test "410 from server is treated as generic error because CalDAVHttp.report does not pass through 410" do
      # BUG: CalDAVHttp.report/5 converts 410 to {:error, "Unexpected status: 410"}
      # before the worker can match {:ok, %Req.Response{status: 410}} in
      # fetch_sync_collection. The sync_token_expired fallback path is unreachable.
      # Fix by adding a 410 clause to CalDAVHttp.report that returns the raw response.
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path1()],
          caldav_sync_token: "stale-sync-token"
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 410, "Gone")
      end)

      assert {:error, "Unexpected status: 410"} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert updated.caldav_sync_token == "stale-sync-token"
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
end
