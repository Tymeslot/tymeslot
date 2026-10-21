defmodule Tymeslot.Workers.SyncCalDavCalendarWorker.RefusedRequestsTest do
  @moduledoc """
  Covers the CalDAV sync worker when the server refuses a request: a 4xx the
  transport layer does not model, redirects (307), 405, a read past the byte
  budget, and a 5xx.
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
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    :ok
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

    test "discards a redirect, which is never followed" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1()]
        )

      # The shape of a provider in maintenance: every DAV path redirected to
      # its status page. Each attempt gets the same 307 back.
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("location", "https://status.example.org/incidents/1")
        |> Conn.send_resp(307, "Temporary Redirect")
      end)

      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "HTTP 307"

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

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

    test "discards a calendar read past the byte budget and counts it against health" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1()]
        )

      oversized = String.duplicate(" ", 8 * 1024 * 1024 + 1)

      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, oversized)
      end)

      # The server answered, and a retry downloads the same oversized answer.
      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason == "CalDAV server returned more data than Tymeslot can process at once"
      # An expected end of the job: no error report every cycle.
      assert SyncCalDavCalendarWorker.expected_outcome?(reason)

      updated =
        Repo.get!(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      # The failure streak is what reaches the owner's integration badge.
      assert Monitor.get_state(:calendar, integration.id, integration.user_id).consecutive_sync_failures ==
               1

      assert updated.calendar_paths == [path1()]
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
end
