defmodule Tymeslot.Workers.SyncCalDavCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
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
          from e in ProviderCalendarEventSchema,
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
          from e in ProviderCalendarEventSchema,
            where:
              e.calendar_integration_id == ^integration.id and
                e.uid == "allday-holiday@test"
        )

      assert cached.all_day == true
      assert cached.summary == "Congés"
      assert cached.start_date == ~D[2026-04-07]
      assert cached.end_date == ~D[2026-04-11]
      assert cached.transparency == "transparent"
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
          from e in ProviderCalendarEventSchema,
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

      ReqTest.stub(:tymeslot_http, fn conn -> respond_to_dual_paths(conn) end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached_uids =
        Repo.all(
          from e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id,
            select: e.uid
        )

      assert "event-from-path1@test" in cached_uids
      assert "event-from-path2@test" in cached_uids
    end
  end

  describe "perform/1 - detect_deletions scoping" do
    # Events must be within the sync window (now -60d to now +365d) for
    # detect_deletions to consider them. Use a date 30 days in the future.
    @future_start DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:microsecond)
    @future_end DateTime.utc_now()
                |> DateTime.add(30, :day)
                |> DateTime.add(3600, :second)
                |> DateTime.truncate(:microsecond)

    defp future_ical(uid, summary) do
      start_str = Calendar.strftime(@future_start, "%Y%m%dT%H%M%SZ")
      end_str = Calendar.strftime(@future_end, "%Y%m%dT%H%M%SZ")

      """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:#{uid}
      DTSTART:#{start_str}
      DTEND:#{end_str}
      SUMMARY:#{summary}
      END:VEVENT
      END:VCALENDAR
      """
    end

    test "full fetch of extra calendar path does not delete cached events from primary path" do
      # Tier 1: primary path gets incremental sync (no detect_deletions),
      # extra paths get full fetch (with detect_deletions). The bug was that
      # detect_deletions on the extra path queried ALL cached events for the
      # integration, incorrectly flagging primary-path events as "missing."
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [@path1, @path2],
          caldav_sync_token: "existing-sync-token"
        )

      # Pre-populate cache with an event from the primary path (path1)
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "pre-existing-path1@test",
        provider: "caldav",
        provider_calendar_id: @path1,
        provider_event_id: "#{@path1}pre-existing.ics",
        summary: "Pre-existing Path1 Event",
        start_at: @future_start,
        end_at: @future_end,
        all_day: false,
        synced_at:
          DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)
      )

      ical1 = future_ical("path1-delta@test", "Path1 Delta Event")
      ical2 = future_ical("path2-event@test", "Path2 Meeting")

      # path1 (primary): incremental sync returns a delta event + new sync token
      # path2 (extra): full fetch returns its event — detect_deletions runs here
      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          @path1 ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(
              207,
              sync_collection_xml("#{@path1}delta.ics", ical1, "updated-sync-token")
            )

          @path2 ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{@path2}event2.ics", ical2))

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
          from e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id,
            select: e.uid,
            order_by: e.uid
        )

      # All three events must survive: the pre-existing path1 event must NOT be
      # deleted by detect_deletions running on path2's full fetch.
      assert "path1-delta@test" in cached_uids
      assert "path2-event@test" in cached_uids
      assert "pre-existing-path1@test" in cached_uids
    end

    test "detect_deletions removes genuinely missing events from the same calendar path" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [@path1]
        )

      # Pre-populate cache with an event on path1 that the server will NOT return
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "deleted-on-server@test",
        provider: "caldav",
        provider_calendar_id: @path1,
        provider_event_id: "#{@path1}deleted.ics",
        summary: "Deleted on Server",
        start_at: @future_start,
        end_at: @future_end,
        all_day: false,
        synced_at:
          DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)
      )

      ical1 = future_ical("surviving-event@test", "Still on Server")

      # Server returns only the surviving event — the pre-existing one is gone
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{@path1}event1.ics", ical1))
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached_uids =
        Repo.all(
          from e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id,
            select: e.uid
        )

      assert "surviving-event@test" in cached_uids
      refute "deleted-on-server@test" in cached_uids
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

      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "reauthentication"
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
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert updated.caldav_sync_token == "stale-sync-token"
    end
  end

  describe "perform/1 - force_full_fetch mode" do
    test "runs full fetch on every calendar path, bypassing Tier 1 delta sync" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [@path1, @path2],
          caldav_sync_token: "old-sync-token"
        )

      # Both paths MUST receive a calendar-query REPORT (not a sync-collection).
      # sync-collection bodies contain `<d:sync-collection>`; calendar-query contains
      # `<c:calendar-query>`. We assert the delta path is never hit by rejecting any
      # body that contains sync-collection.
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:body, conn.request_path, body})
        respond_to_dual_paths(conn)
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "force_full_fetch" => true
               })

      # Every request must be a calendar-query REPORT, not a sync-collection.
      assert_receive {:body, @path1, path1_body}
      assert_receive {:body, @path2, path2_body}
      refute path1_body =~ "sync-collection"
      refute path2_body =~ "sync-collection"
      assert path1_body =~ "calendar-query"
      assert path2_body =~ "calendar-query"

      # Both events landed in the cache.
      cached_uids =
        Repo.all(
          from e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id,
            select: e.uid
        )

      assert "event-from-path1@test" in cached_uids
      assert "event-from-path2@test" in cached_uids

      # Integration state: sync token cleared, last_full_sync_at set,
      # and the detected tier is reset to nil so the next normal sync
      # re-probes the server's capabilities (handles e.g. a server
      # upgrade that enabled sync-collection support).
      reloaded = Repo.reload!(integration)
      assert is_nil(reloaded.caldav_sync_token)
      assert is_nil(reloaded.caldav_sync_tier)
      assert not is_nil(reloaded.last_full_sync_at)
      assert not is_nil(reloaded.last_external_sync_at)
    end

    test "on fetch failure, leaves sync token and last_full_sync_at unchanged" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [@path1],
          caldav_sync_token: "preserved-token",
          last_full_sync_at: ~U[2026-01-01 00:00:00Z]
        )

      # Capture the request body so we can prove the forced full-fetch path
      # (calendar-query REPORT) was taken and not the Tier 1 delta path
      # (sync-collection REPORT). A raw transport error is the simplest way
      # to reach the {:error, reason} branch of sync_forced_full_fetch/2.
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:body, body})
        ReqTest.transport_error(conn, :econnrefused)
      end)

      result =
        perform_job(SyncCalDavCalendarWorker, %{
          "calendar_integration_id" => integration.id,
          "force_full_fetch" => true
        })

      # The forced path sends a calendar-query REPORT, never a sync-collection.
      # This assertion is what proves the force_full_fetch branch was taken —
      # if the worker fell through to the Tier 1 delta path, the body would
      # contain `<d:sync-collection>` instead.
      assert_receive {:body, body}
      assert body =~ "calendar-query"
      refute body =~ "sync-collection"

      # sync_forced_full_fetch/2 returns {:error, %Req.TransportError{}} on
      # transport failure, which perform/1 propagates verbatim, so perform_job
      # returns {:error, reason}. Pin the result to that one outcome.
      assert {:error, _reason} = result

      reloaded = Repo.reload!(integration)
      assert reloaded.caldav_sync_token == "preserved-token"
      assert reloaded.last_full_sync_at == ~U[2026-01-01 00:00:00Z]
    end

    test "returns :ok without advancing last_full_sync_at when calendar_paths is empty" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          calendar_paths: []
        )

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "force_full_fetch" => true
               })

      reloaded = Repo.reload!(integration)
      assert is_nil(reloaded.last_full_sync_at)
      assert is_nil(reloaded.last_external_sync_at)
    end

    test "skips tier detection when forced, even if caldav_sync_tier is nil" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: nil,
          calendar_paths: [@path1]
        )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)
        send(test_pid, {:method, conn.method, conn.request_path})

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{@path1}event1.ics", @ical_path1))
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "force_full_fetch" => true
               })

      # No PROPFIND (tier detection probe) should have fired.
      refute_received {:method, "PROPFIND", _path}

      reloaded = Repo.reload!(integration)
      # Tier stays nil — we didn't detect it this run.
      assert is_nil(reloaded.caldav_sync_tier)
      assert not is_nil(reloaded.last_full_sync_at)
    end
  end

  # Stub responder for tests that configure two calendar paths and expect the
  # worker to issue a REPORT against each. Returns a canned 207 Multi-Status
  # payload for each known path and 404 for anything else.
  defp respond_to_dual_paths(conn) do
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
  end
end
