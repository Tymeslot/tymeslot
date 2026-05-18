defmodule Tymeslot.Workers.SyncCalDavCalendarWorker.DeletionsTest do
  @moduledoc """
  Covers `detect_deletions` scoping in the CalDAV sync worker — the path that
  prunes cached events the server no longer returns, scoped per calendar path
  so multi-calendar integrations don't cross-delete.
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
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    :ok
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
          calendar_paths: [path1(), path2()],
          caldav_sync_token: "existing-sync-token"
        )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "pre-existing-path1@test",
        provider: "caldav",
        provider_calendar_id: path1(),
        provider_event_id: "#{path1()}pre-existing.ics",
        summary: "Pre-existing Path1 Event",
        start_at: @future_start,
        end_at: @future_end,
        all_day: false,
        synced_at:
          DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)
      )

      ical1 = future_ical("path1-delta@test", "Path1 Delta Event")
      ical2 = future_ical("path2-event@test", "Path2 Meeting")
      path_a = path1()
      path_b = path2()

      # path1 (primary): incremental sync returns a delta event + new sync token
      # path2 (extra): full fetch returns its event — detect_deletions runs here
      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          ^path_a ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(
              207,
              sync_collection_xml("#{path_a}delta.ics", ical1, "updated-sync-token")
            )

          ^path_b ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{path_b}event2.ics", ical2))

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
          calendar_paths: [path1()]
        )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "deleted-on-server@test",
        provider: "caldav",
        provider_calendar_id: path1(),
        provider_event_id: "#{path1()}deleted.ics",
        summary: "Deleted on Server",
        start_at: @future_start,
        end_at: @future_end,
        all_day: false,
        synced_at:
          DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)
      )

      ical1 = future_ical("surviving-event@test", "Still on Server")

      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{path1()}event1.ics", ical1))
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
end
