defmodule Tymeslot.Workers.SyncCalDavCalendarWorker.TierSyncTest do
  @moduledoc """
  Covers the worker's per-tier sync paths (Tier 1 incremental + extras,
  Tier 2 CTag-based, Tier 3 full fetch) and all-day event handling.
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

  describe "perform/1 - Tier 1 multi-path sync" do
    test "syncs events from all calendar paths: delta sync for primary, full fetch for extras" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path1(), path2()],
          caldav_sync_token: "old-sync-token"
        )

      path_a = path1()
      path_b = path2()

      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          ^path_a ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(
              207,
              sync_collection_xml("#{path_a}event1.ics", ical_path1(), "new-sync-token")
            )

          ^path_b ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{path_b}event2.ics", ical_path2()))

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
          calendar_paths: [path1()]
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
        |> Conn.send_resp(207, caldav_report_xml("#{path1()}holiday.ics", allday_ical))
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
          calendar_paths: [path1(), path2()],
          caldav_sync_token: nil
        )

      path_a = path1()
      path_b = path2()

      ReqTest.stub(:tymeslot_http, fn conn ->
        case {conn.method, conn.request_path} do
          {"PROPFIND", ^path_a} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, ctag_xml("new-ctag"))

          {_method, ^path_a} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{path_a}event1.ics", ical_path1()))

          {_method, ^path_b} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, caldav_report_xml("#{path_b}event2.ics", ical_path2()))

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
          calendar_paths: [path1(), path2()]
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
end
