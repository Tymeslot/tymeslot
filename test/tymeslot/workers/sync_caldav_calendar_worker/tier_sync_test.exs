defmodule Tymeslot.Workers.SyncCalDavCalendarWorker.TierSyncTest do
  @moduledoc """
  Covers the worker's per-tier sync paths (Tier 1 incremental and Tier 2
  CTag-based, each per calendar path, and Tier 3 full fetch) and all-day
  event handling.
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
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    :ok
  end

  describe "perform/1 - Tier 1 multi-path sync" do
    test "delta-syncs every calendar path against its own sync token" do
      path_a = path1()
      path_b = path2()

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path_a, path_b],
          caldav_sync_tokens: %{path_a => "token-a", path_b => "token-b"}
        )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:body, conn.request_path, body})

        {href, ical, new_token} =
          case conn.request_path do
            ^path_a -> {"#{path_a}event1.ics", ical_path1(), "token-a2"}
            ^path_b -> {"#{path_b}event2.ics", ical_path2(), "token-b2"}
          end

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, sync_collection_xml(href, ical, new_token))
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      # Each calendar asked for its own delta; neither was fetched in full.
      assert_received {:body, ^path_a, body_a}
      assert_received {:body, ^path_b, body_b}
      assert body_a =~ "<d:sync-token>token-a</d:sync-token>"
      assert body_b =~ "<d:sync-token>token-b</d:sync-token>"
      refute_received {:body, _path, _body}

      cached_uids =
        Repo.all(
          from e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id,
            select: e.uid
        )

      assert "event-from-path1@test" in cached_uids
      assert "event-from-path2@test" in cached_uids

      assert Repo.reload!(integration).caldav_sync_tokens ==
               %{path_a => "token-a2", path_b => "token-b2"}
    end

    test "an expired token on one path re-fetches that path alone and keeps the other's" do
      path_a = path1()
      path_b = path2()

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path_a, path_b],
          caldav_sync_tokens: %{path_a => "token-a", path_b => "stale-token-b"}
        )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        kind = if body =~ "sync-collection", do: :sync_collection, else: :calendar_query
        send(test_pid, {kind, conn.request_path})

        case {kind, conn.request_path} do
          {:sync_collection, ^path_a} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(
              207,
              sync_collection_xml("#{path_a}event1.ics", ical_path1(), "token-a2")
            )

          {:sync_collection, ^path_b} ->
            Conn.send_resp(conn, 410, "Gone")

          {:calendar_query, _path} ->
            respond_to_dual_paths(conn)
        end
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_received {:calendar_query, ^path_b}
      refute_received {:calendar_query, ^path_a}

      # Path B restarts from nothing next cycle; path A's advance survives.
      assert Repo.reload!(integration).caldav_sync_tokens == %{path_a => "token-a2"}
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
    test "fetches only the calendars whose CTag moved, and records each path's CTag" do
      path_a = path1()
      path_b = path2()

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 2,
          calendar_paths: [path_a, path_b],
          caldav_sync_tokens: %{path_a => "ctag-a", path_b => "ctag-b"}
        )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {conn.method, conn.request_path})

        case {conn.method, conn.request_path} do
          {"PROPFIND", ^path_a} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, ctag_xml("ctag-a"))

          {"PROPFIND", ^path_b} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, ctag_xml("ctag-b2"))

          {"REPORT", _path} ->
            respond_to_dual_paths(conn)
        end
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      # The unchanged primary is skipped; only the extra calendar is fetched.
      assert_received {"REPORT", ^path_b}
      refute_received {"REPORT", ^path_a}

      assert {:ok, _event} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "event-from-path2@test")

      assert Repo.reload!(integration).caldav_sync_tokens ==
               %{path_a => "ctag-a", path_b => "ctag-b2"}
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

  describe "no calendar selected" do
    for tier <- [1, 2, 3] do
      @tier tier

      test "tier #{@tier} flags for reconnection when calendar_paths is empty" do
        integration =
          insert(:calendar_integration,
            provider: "caldav",
            is_active: true,
            caldav_sync_tier: @tier,
            calendar_paths: []
          )

        assert {:discard, _reason} =
                 perform_job(SyncCalDavCalendarWorker, %{
                   "calendar_integration_id" => integration.id
                 })

        reloaded = Repo.reload!(integration)
        assert reloaded.needs_reauth
        assert reloaded.sync_error =~ "No calendar is selected"
        assert is_nil(reloaded.last_external_sync_at)
      end
    end
  end
end
