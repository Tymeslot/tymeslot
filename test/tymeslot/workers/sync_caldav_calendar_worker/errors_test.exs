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
end
