defmodule Tymeslot.Integrations.Calendar.CalDAV.SyncCycleTest do
  @moduledoc """
  One CalDAV sync cycle (`CalDAV.Sync.run/2`), run without Oban: what it
  caches, and the outcome a failed one hands its caller with nothing
  recorded against the integration.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.CalDAVSyncTestFixtures
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.CalDAV.Sync, as: CalDAVSync
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})

    inserted =
      insert(:calendar_integration,
        provider: "caldav",
        is_active: true,
        needs_reauth: false,
        sync_error: nil,
        caldav_sync_tier: 3,
        calendar_paths: [path1(), path2()]
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
    %{integration: integration}
  end

  defp cached_uids(integration) do
    Repo.all(
      from e in ProviderCalendarEventSchema,
        where: e.calendar_integration_id == ^integration.id,
        select: e.uid,
        order_by: e.uid
    )
  end

  test "a full fetch caches every calendar path", %{integration: integration} do
    ReqTest.stub(:tymeslot_http, &respond_to_dual_paths/1)

    assert :ok = CalDAVSync.run(integration, true)
    assert cached_uids(integration) == ["event-from-path1@test", "event-from-path2@test"]
  end

  test "a refused credential is :unauthorized, with nothing recorded", %{
    integration: integration
  } do
    ReqTest.stub(:tymeslot_http, &Conn.send_resp(&1, 401, "Unauthorized"))

    assert {:error, :unauthorized} = CalDAVSync.run(integration, true)

    assert {:ok, %{needs_reauth: false, sync_error: nil}} =
             CalendarIntegrationQueries.get(integration.id)
  end

  describe "a calendar shared as busy times only" do
    # It answers calendar-query with 403, so its events are never asked for;
    # its busy periods, from the free-busy-query REPORT, are cached
    # `busy_only` under its path for the feed and the audit.
    defp sharing(paths_and_flags, attrs \\ []) do
      inserted =
        insert(
          :calendar_integration,
          Keyword.merge(
            [
              provider: "caldav",
              is_active: true,
              caldav_sync_tier: 3,
              calendar_paths: Enum.map(paths_and_flags, &elem(&1, 0)),
              calendar_list:
                for {path, free_busy_only?} <- paths_and_flags do
                  %{id: path, path: path, selected: true, free_busy_only: free_busy_only?}
                end
            ],
            attrs
          )
        )

      {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
      integration
    end

    # Tells `test_pid` of every request for the shared path; answers its
    # free-busy-query with `answer`, its calendar-query with 403.
    defp sharing_server(test_pid, answer) do
      fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        cond do
          conn.request_path != path2() ->
            respond_to_dual_paths(conn)

          body =~ "free-busy-query" ->
            send(test_pid, {:asked, :free_busy})
            answer.(conn)

          true ->
            send(test_pid, {:asked, :calendar_query})
            Conn.send_resp(conn, 403, "Forbidden")
        end
      end
    end

    defp vfreebusy(periods) do
      Enum.join(
        ["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VFREEBUSY"] ++
          Enum.map(periods, &"FREEBUSY:#{&1}") ++ ["END:VFREEBUSY", "END:VCALENDAR", ""],
        "\r\n"
      )
    end

    defp tomorrow_at(hour) do
      Date.utc_today()
      |> Date.add(1)
      |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
    end

    defp period(hour), do: "#{Calendar.strftime(tomorrow_at(hour), "%Y%m%dT%H%M%SZ")}/PT1H"

    defp busy_rows(integration) do
      rows =
        Repo.all(
          from e in ProviderCalendarEventSchema,
            where:
              e.calendar_integration_id == ^integration.id and
                e.provider_calendar_id == ^path2(),
            select: {e.role, e.start_at},
            order_by: e.start_at
        )

      Enum.map(rows, fn {role, start_at} -> {role, DateTime.truncate(start_at, :second)} end)
    end

    defp serve(answer), do: ReqTest.stub(:tymeslot_http, sharing_server(self(), answer))

    defp answer_periods(periods),
      do: &Conn.send_resp(&1, 200, vfreebusy(periods))

    test "caches its busy periods, never asking for its events" do
      integration = sharing([{path1(), false}, {path2(), true}])
      serve(answer_periods([period(9), period(14)]))

      assert :ok = CalDAVSync.run(integration, true)

      assert busy_rows(integration) == [
               {"busy_only", tomorrow_at(9)},
               {"busy_only", tomorrow_at(14)}
             ]

      assert "event-from-path1@test" in cached_uids(integration)
      assert_received {:asked, :free_busy}
      refute_received {:asked, :calendar_query}

      # Busy time with nothing to show: the grid lists none of it.
      refute integration.id
             |> List.wrap()
             |> CalendarGrid.list_events_for_range(tomorrow_at(0), tomorrow_at(23))
             |> Enum.any?(&(&1.provider_calendar_id == path2()))
    end

    test "an answer with no busy periods clears them" do
      integration = sharing([{path2(), true}])
      serve(answer_periods([period(9)]))
      assert :ok = CalDAVSync.run(integration, false)
      assert [_busy] = busy_rows(integration)

      serve(answer_periods([]))
      assert :ok = CalDAVSync.run(integration, false)
      assert busy_rows(integration) == []
    end

    test "a refused read keeps the last periods and asks for no reconnect" do
      integration = sharing([{path2(), true}])
      serve(answer_periods([period(9)]))
      assert :ok = CalDAVSync.run(integration, false)

      serve(&Conn.send_resp(&1, 403, "Forbidden"))

      assert {:error, {:free_busy_unreadable, _reason}} = CalDAVSync.run(integration, false)
      assert [{"busy_only", _start}] = busy_rows(integration)

      assert {:ok, %{needs_reauth: false}} = CalendarIntegrationQueries.get(integration.id)
    end

    test "a refused read is recorded for health, never as a reason to reconnect" do
      integration = sharing([{path2(), true}])
      serve(&Conn.send_resp(&1, 403, "Forbidden"))

      assert {:discard, _reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert {:ok, %{needs_reauth: false, sync_error: sync_error}} =
               CalendarIntegrationQueries.get(integration.id)

      assert sync_error =~ "busy times only"
    end

    test "widened to a full share, its busy periods go and its events come" do
      integration = sharing([{path1(), false}, {path2(), true}])
      serve(answer_periods([period(9)]))
      assert :ok = CalDAVSync.run(integration, true)
      assert [{"busy_only", _start}] = busy_rows(integration)

      {:ok, widened} =
        integration
        |> Changeset.change(
          calendar_list: Enum.map(integration.calendar_list, &%{&1 | free_busy_only: false})
        )
        |> Repo.update()

      ReqTest.stub(:tymeslot_http, &respond_to_dual_paths/1)

      assert :ok = CalDAVSync.run(widened, true)
      refute Enum.any?(busy_rows(widened), &match?({"busy_only", _start}, &1))
      assert "event-from-path2@test" in cached_uids(widened)
    end

    test "refused credentials ask for a reconnect, as on any other read" do
      integration = sharing([{path2(), true}])
      serve(answer_periods([period(9)]))
      assert :ok = CalDAVSync.run(integration, false)

      serve(&Conn.send_resp(&1, 401, "Unauthorized"))

      assert {:error, :unauthorized} = CalDAVSync.run(integration, false)
      assert [{"busy_only", _start}] = busy_rows(integration)

      perform_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert {:ok, %{needs_reauth: true}} = CalendarIntegrationQueries.get(integration.id)
    end

    test "periods it cannot cache fail the sync, not the calendar's read" do
      integration = sharing([{path2(), true}])

      # The integration goes while its answer is on the way: the rows have
      # nothing to belong to.
      serve(fn conn ->
        Repo.delete_all(
          from i in CalendarIntegrationSchema,
            where: i.id == ^integration.id
        )

        answer_periods([period(9)]).(conn)
      end)

      assert {:error, reason} = CalDAVSync.run(integration, false)
      refute match?({:free_busy_unreadable, _reason}, reason)
    end

    test "flushes changes queued earlier even with nothing else to sync" do
      integration = sharing([{path2(), true}])

      queued =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "caldav",
          provider_calendar_id: path1(),
          provider_event_id: "#{path1()}queued.ics",
          uid: "queued",
          etag: "\"etag\"",
          sync_state: "locally_modified"
        )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        if conn.method == "PUT" do
          send(test_pid, :flushed)
          Conn.send_resp(conn, 204, "")
        else
          sharing_server(test_pid, answer_periods([])).(conn)
        end
      end)

      assert :ok = CalDAVSync.run(integration, false)
      assert_received :flushed
      assert Repo.reload!(queued).sync_state == "synced"
    end
  end

  test "a server that does not answer is the cycle's outcome", %{integration: integration} do
    ReqTest.stub(:tymeslot_http, &ReqTest.transport_error(&1, :timeout))

    assert {:error, reason} = CalDAVSync.run(integration, true)
    assert reason in [:timeout, :server_unresponsive, :network_error]
    assert cached_uids(integration) == []
  end
end
