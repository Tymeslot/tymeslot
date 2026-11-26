defmodule Tymeslot.Workers.SyncCalDavCalendarWorker.DeletionRefusalsTest do
  @moduledoc """
  How the CalDAV walk combines the deletion breaker's refusal with the other
  outcomes a path can have: another refusal, a hard error, a missing
  collection, and a CTag that must not advance past an unapplied listing.
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
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @path3 "/calendars/user/shared/"

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    :ok
  end

  defp report(conn, entries) do
    conn
    |> Conn.put_resp_header("content-type", "application/xml")
    |> Conn.send_resp(207, caldav_report_xml(entries))
  end

  defp listing(path, uids), do: Enum.map(uids, &{"#{path}#{&1}.ics", future_ical(&1)})

  defp cached_uids(integration) do
    Repo.all(
      from e in ProviderCalendarEventSchema,
        where: e.calendar_integration_id == ^integration.id,
        select: e.uid,
        order_by: e.uid
    )
  end

  defp run(integration),
    do: perform_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})

  defp reload(integration), do: Repo.get!(CalendarIntegrationSchema, integration.id)

  describe "two refusals in one walk" do
    test "both caches stay, one refusal is reported, a third calendar still syncs" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1(), path2(), @path3]
        )

      refused1 = ["r1-a@test", "r1-b@test"]
      refused2 = ["r2-a@test", "r2-b@test"]
      insert_confirmed_events(integration, path1(), refused1)
      insert_confirmed_events(integration, path2(), refused2)

      path_a = path1()
      path_b = path2()
      path_c = @path3

      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          ^path_a -> report(conn, [])
          ^path_b -> report(conn, [])
          ^path_c -> report(conn, listing(path_c, ["healthy@test"]))
        end
      end)

      assert {:discard, reason} = run(integration)
      assert reason =~ "circuit breaker"
      assert cached_uids(integration) == Enum.sort(["healthy@test" | refused1 ++ refused2])
    end
  end

  describe "a refusal and a hard error in one walk" do
    test "a hard error after a refusal wins and stops the walk" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1(), path2(), @path3]
        )

      refused = ["r-a@test", "r-b@test"]
      insert_confirmed_events(integration, path1(), refused)

      test_pid = self()
      path_a = path1()
      path_b = path2()
      path_c = @path3

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:requested, conn.request_path})

        case conn.request_path do
          ^path_a -> report(conn, [])
          ^path_b -> Conn.send_resp(conn, 401, "Unauthorized")
          ^path_c -> report(conn, listing(path_c, ["never-reached@test"]))
        end
      end)

      assert {:discard, reason} = run(integration)
      assert reason =~ "reauthentication"
      refute reason =~ "circuit breaker"

      assert_received {:requested, ^path_a}
      assert_received {:requested, ^path_b}
      refute_received {:requested, ^path_c}
      assert cached_uids(integration) == Enum.sort(refused)
    end

    test "a hard error before a refusal wins and the refused calendar is never listed" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1(), path2()]
        )

      refused = ["r-a@test", "r-b@test"]
      insert_confirmed_events(integration, path2(), refused)

      test_pid = self()
      path_a = path1()
      path_b = path2()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:requested, conn.request_path})

        case conn.request_path do
          ^path_a -> Conn.send_resp(conn, 401, "Unauthorized")
          ^path_b -> report(conn, [])
        end
      end)

      assert {:discard, reason} = run(integration)
      assert reason =~ "reauthentication"
      refute reason =~ "circuit breaker"

      assert_received {:requested, ^path_a}
      refute_received {:requested, ^path_b}
      assert cached_uids(integration) == Enum.sort(refused)
    end
  end

  describe "a refusal and a missing calendar in one walk" do
    defp stub_path1_refused_path2_gone do
      path_a = path1()

      ReqTest.stub(:tymeslot_http, fn conn ->
        if conn.request_path == path_a,
          do: report(conn, []),
          else: Conn.send_resp(conn, 404, "Not Found")
      end)
    end

    test "a missing non-booking calendar is removed and the refusal is still reported" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1(), path2()],
          default_booking_calendar_id: path1(),
          calendar_list: [
            %{id: path1(), path: path1(), name: "Bookings", selected: true},
            %{id: path2(), path: path2(), name: "Shared", selected: true, read_only: true}
          ]
        )

      refused = ["r-a@test", "r-b@test"]
      insert_confirmed_events(integration, path1(), refused)
      stub_path1_refused_path2_gone()

      assert {:discard, reason} = run(integration)
      assert reason =~ "circuit breaker"

      updated = reload(integration)
      assert updated.calendar_paths == [path1()]
      assert Enum.find(updated.calendar_list, &(&1.path == path2())).selected == false
      assert updated.needs_reauth == false
      assert cached_uids(integration) == Enum.sort(refused)
    end

    test "a missing booking calendar overrides the refusal and is flagged, not removed" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: [path1(), path2()],
          default_booking_calendar_id: path2(),
          calendar_list: [
            %{id: path1(), path: path1(), name: "Personal", selected: true},
            %{id: path2(), path: path2(), name: "Bookings", selected: true}
          ]
        )

      refused = ["r-a@test", "r-b@test"]
      insert_confirmed_events(integration, path1(), refused)
      stub_path1_refused_path2_gone()

      assert {:discard, reason} = run(integration)
      refute reason =~ "circuit breaker"

      updated = reload(integration)
      assert updated.needs_reauth == true
      assert updated.sync_error =~ "no longer exists"
      assert path2() in updated.calendar_paths
      assert cached_uids(integration) == Enum.sort(refused)
    end
  end

  describe "Tier 2 CTag handling around a refusal" do
    test "the refused path's CTag is not stored, the healthy path's is" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 2,
          calendar_paths: [path1(), path2()],
          caldav_sync_tokens: %{path1() => "ctag-a", path2() => "ctag-b"}
        )

      refused = ["r-a@test", "r-b@test"]
      insert_confirmed_events(integration, path1(), refused)

      path_a = path1()
      path_b = path2()

      ReqTest.stub(:tymeslot_http, fn conn ->
        case {conn.method, conn.request_path} do
          {"PROPFIND", ^path_a} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, ctag_xml("ctag-a2"))

          {"PROPFIND", ^path_b} ->
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, ctag_xml("ctag-b2"))

          {"REPORT", ^path_a} ->
            report(conn, [])

          {"REPORT", ^path_b} ->
            report(conn, listing(path_b, ["healthy@test"]))
        end
      end)

      assert {:discard, reason} = run(integration)
      assert reason =~ "circuit breaker"

      tokens = reload(integration).caldav_sync_tokens
      assert tokens[path1()] == "ctag-a"
      assert tokens[path2()] == "ctag-b2"
      assert cached_uids(integration) == Enum.sort(["healthy@test" | refused])
    end
  end
end
