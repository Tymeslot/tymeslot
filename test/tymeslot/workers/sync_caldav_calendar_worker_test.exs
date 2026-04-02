defmodule Tymeslot.Workers.SyncCalDavCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.DatabaseSchemas.CalendarEventCacheSchema
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  # Switch from HTTPClientMock to the real HTTPClient so Req.Test intercepts calls.
  # set_req_test_to_shared makes the stub visible across process boundaries (e.g. the
  # CalendarCircuitBreaker GenServer which executes the HTTP call in its own process).
  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    :ok
  end

  @path1 "/calendars/user/work/"
  @path2 "/calendars/user/personal/"

  @ical_path1 """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//Test//EN
  BEGIN:VEVENT
  UID:event-from-path1@test
  DTSTART:20991215T100000Z
  DTEND:20991215T110000Z
  SUMMARY:Path1 Meeting
  END:VEVENT
  END:VCALENDAR
  """

  @ical_path2 """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//Test//EN
  BEGIN:VEVENT
  UID:event-from-path2@test
  DTSTART:20991215T140000Z
  DTEND:20991215T150000Z
  SUMMARY:Path2 Meeting
  END:VEVENT
  END:VCALENDAR
  """

  defp caldav_report_xml(href, ical_data) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>#{href}</D:href>
        <D:propstat>
          <D:prop>
            <D:getetag>"test-etag"</D:getetag>
            <C:calendar-data>#{String.trim(ical_data)}</C:calendar-data>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end

  defp sync_collection_xml(href, ical_data, sync_token) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>#{href}</D:href>
        <D:propstat>
          <D:prop>
            <D:getetag>"test-etag"</D:getetag>
            <C:calendar-data>#{String.trim(ical_data)}</C:calendar-data>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:sync-token>#{sync_token}</D:sync-token>
    </D:multistatus>
    """
  end

  defp ctag_xml(ctag) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">
      <D:response>
        <D:propstat>
          <D:prop>
            <CS:getctag>#{ctag}</CS:getctag>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end

  describe "perform/1 - Tier 1 multi-path sync" do
    test "syncs events from all calendar paths: delta sync for primary, full fetch for extras" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [@path1, @path2],
          caldav_sync_token: "old-sync-token"
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          @path1 ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(
              207,
              sync_collection_xml("#{@path1}event1.ics", @ical_path1, "new-sync-token")
            )

          @path2 ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{@path2}event2.ics", @ical_path2))

          other ->
            Conn.send_resp(conn, 404, "unexpected path: #{other}")
        end
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached_uids =
        Repo.all(
          from e in CalendarEventCacheSchema,
            where: e.calendar_integration_id == ^integration.id,
            select: e.uid
        )

      assert "event-from-path1@test" in cached_uids
      assert "event-from-path2@test" in cached_uids
    end
  end

  describe "perform/1 - all-day events" do
    test "caches multi-day all-day event with correct all_day flag and UTC-midnight timestamps" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [@path1]
        )

      allday_ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:Zimbra-Calendar-Provider
      BEGIN:VEVENT
      UID:allday-holiday@test
      DTSTART;VALUE=DATE:20260407
      DTEND;VALUE=DATE:20260411
      SUMMARY:Congés
      TRANSP:TRANSPARENT
      END:VEVENT
      END:VCALENDAR
      """

      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{@path1}holiday.ics", allday_ical))
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached =
        Repo.one!(
          from e in CalendarEventCacheSchema,
            where:
              e.calendar_integration_id == ^integration.id and
                e.uid == "allday-holiday@test"
        )

      assert cached.all_day == true
      assert cached.title == "Congés"
      assert cached.start_at == ~U[2026-04-07 00:00:00Z]
      assert cached.end_at == ~U[2026-04-11 00:00:00Z]
      assert cached.status == "free"
    end
  end

  describe "perform/1 - Tier 2 multi-path sync" do
    test "syncs events from all calendar paths when CTag changes" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 2,
          calendar_paths: [@path1, @path2],
          caldav_sync_token: nil
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        case {conn.method, conn.request_path} do
          {"PROPFIND", @path1} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, ctag_xml("new-ctag"))

          {_method, @path1} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{@path1}event1.ics", @ical_path1))

          {_method, @path2} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{@path2}event2.ics", @ical_path2))

          {method, path} ->
            Conn.send_resp(conn, 404, "unexpected #{method} #{path}")
        end
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached_uids =
        Repo.all(
          from e in CalendarEventCacheSchema,
            where: e.calendar_integration_id == ^integration.id,
            select: e.uid
        )

      assert "event-from-path1@test" in cached_uids
      assert "event-from-path2@test" in cached_uids
    end
  end

  describe "perform/1 - Tier 3 multi-path sync" do
    test "syncs events from all configured calendar paths, not just the first" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [@path1, @path2]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          @path1 ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{@path1}event1.ics", @ical_path1))

          @path2 ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{@path2}event2.ics", @ical_path2))

          other ->
            Conn.send_resp(conn, 404, "unexpected path: #{other}")
        end
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached_uids =
        Repo.all(
          from e in CalendarEventCacheSchema,
            where: e.calendar_integration_id == ^integration.id,
            select: e.uid
        )

      assert "event-from-path1@test" in cached_uids
      assert "event-from-path2@test" in cached_uids
    end
  end

  describe "perform/1 - auth failures" do
    test "returns :ok without retrying when CalDAV server returns 401" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [@path1]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "Unauthorized")
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
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
          calendar_paths: [@path1],
          caldav_sync_token: "stale-sync-token"
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 410, "Gone")
      end)

      # Actual behaviour: worker returns error instead of falling back to full fetch
      assert {:error, "Unexpected status: 410"} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      # Sync token is NOT cleared because the sync_token_expired handler is never reached
      updated =
        Repo.get!(Tymeslot.DatabaseSchemas.CalendarIntegrationSchema, integration.id)

      assert updated.caldav_sync_token == "stale-sync-token"
    end
  end
end
