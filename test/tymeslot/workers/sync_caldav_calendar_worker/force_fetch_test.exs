defmodule Tymeslot.Workers.SyncCalDavCalendarWorker.ForceFetchTest do
  @moduledoc """
  Covers the worker's `force_full_fetch` mode: bypasses Tier 1 delta sync,
  issues a calendar-query REPORT against every path, resets sync state on
  success, and preserves it on failure.
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

  describe "perform/1 - force_full_fetch mode" do
    test "runs full fetch on every calendar path, bypassing Tier 1 delta sync" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path1(), path2()],
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

      path_a = path1()
      path_b = path2()

      assert_receive {:body, ^path_a, path1_body}
      assert_receive {:body, ^path_b, path2_body}
      refute path1_body =~ "sync-collection"
      refute path2_body =~ "sync-collection"
      assert path1_body =~ "calendar-query"
      assert path2_body =~ "calendar-query"

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
          calendar_paths: [path1()],
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

      assert_receive {:body, body}
      assert body =~ "calendar-query"
      refute body =~ "sync-collection"

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
          calendar_paths: [path1()]
        )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, _body, conn} = Conn.read_body(conn)
        send(test_pid, {:method, conn.method, conn.request_path})

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{path1()}event1.ics", ical_path1()))
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "force_full_fetch" => true
               })

      # No PROPFIND (tier detection probe) should have fired.
      refute_received {:method, "PROPFIND", _path}

      reloaded = Repo.reload!(integration)
      assert is_nil(reloaded.caldav_sync_tier)
      assert not is_nil(reloaded.last_full_sync_at)
    end
  end
end
