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
  alias Tymeslot.Integrations.Calendar.CalDAV.SyncCollectionReport
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

    test "an expired token on one path restarts that path alone and keeps the other's" do
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

      stub_tier1_server(%{path_a => {:delta, "token-a2"}, path_b => :gone},
        fresh_token: "token-b-fresh"
      )

      assert :ok = run_sync(integration)

      assert_received {:calendar_query, ^path_b}
      refute_received {:calendar_query, ^path_a}

      # Path B restarted from a token read in the same cycle; path A's advance
      # survives.
      assert Repo.reload!(integration).caldav_sync_tokens ==
               %{path_a => "token-a2", path_b => "token-b-fresh"}
    end
  end

  # A path with no token used to send the initial sync-collection REPORT, which
  # returns the collection's whole history with every event body inline and no
  # time range. On a large calendar that response took the node down, and the
  # token it would have produced was never stored, so it repeated every cycle.
  describe "perform/1 - Tier 1 path with no sync token" do
    setup do
      path_a = path1()
      path_b = path2()

      # Path B is the upgrade case: per-path tokens only carried the old token
      # across for the primary calendar.
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path_a, path_b],
          caldav_sync_tokens: %{path_a => "token-a"}
        )

      %{integration: integration, path_a: path_a, path_b: path_b}
    end

    test "reads the token and fetches the sync window instead of the whole collection",
         %{integration: integration, path_a: path_a, path_b: path_b} do
      stub_tier1_server(%{path_a => {:delta, "token-a2"}, path_b => :no_token},
        fresh_token: "token-b1"
      )

      assert :ok = run_sync(integration)

      # The token was read before the events were fetched, and nothing asked
      # path B for a sync-collection.
      assert requests_for(path_b) == [:propfind_sync_token, :calendar_query]

      assert "event-from-path2@test" in cached_uids(integration)

      assert Repo.reload!(integration).caldav_sync_tokens ==
               %{path_a => "token-a2", path_b => "token-b1"}
    end

    test "asks for the delta since the token it read on the next cycle",
         %{integration: integration, path_a: path_a, path_b: path_b} do
      stub_tier1_server(%{path_a => {:delta, "token-a2"}, path_b => :no_token},
        fresh_token: "token-b1"
      )

      assert :ok = run_sync(integration)

      stub_tier1_server(%{path_a => {:delta, "token-a3"}, path_b => {:delta, "token-b2"}})

      assert :ok = run_sync(Repo.reload!(integration))

      assert_received {:sync_collection, ^path_b, body}
      assert body =~ "<d:sync-token>token-b1</d:sync-token>"
      assert Repo.reload!(integration).caldav_sync_tokens[path_b] == "token-b2"
    end

    test "still syncs the path when the token cannot be read, and leaves it without one",
         %{integration: integration, path_a: path_a, path_b: path_b} do
      stub_tier1_server(%{path_a => {:delta, "token-a2"}, path_b => :no_token},
        token_probe: :fail
      )

      assert :ok = run_sync(integration)

      assert "event-from-path2@test" in cached_uids(integration)
      assert Repo.reload!(integration).caldav_sync_tokens == %{path_a => "token-a2"}
    end

    test "does not store the token it read when the fetch that follows fails",
         %{integration: integration, path_a: path_a, path_b: path_b} do
      # Storing it anyway would skip every event the failed fetch never
      # delivered: the next delta starts after them.
      stub_tier1_server(%{path_a => {:delta, "token-a2"}, path_b => :no_token},
        fresh_token: "token-b1",
        calendar_query: :fail
      )

      run_sync(integration)

      refute Map.has_key?(Repo.reload!(integration).caldav_sync_tokens, path_b)
    end
  end

  # A bulk change on the server (an import, a migration) can return a delta
  # whose DOM alone exhausts the node's memory. It is abandoned mid-transfer,
  # and the path restarts from a fresh token rather than asking for the same
  # delta every cycle.
  describe "perform/1 - Tier 1 delta too large to read" do
    setup do
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

      %{integration: integration, path_a: path_a, path_b: path_b}
    end

    test "fetches the sync window and stores a token read before it",
         %{integration: integration, path_a: path_a, path_b: path_b} do
      stub_tier1_server(%{path_a => {:delta, "token-a2"}, path_b => :too_large},
        fresh_token: "token-b-fresh"
      )

      assert :ok = run_sync(integration)

      assert requests_for(path_b) == [:sync_collection, :propfind_sync_token, :calendar_query]
      assert "event-from-path2@test" in cached_uids(integration)

      assert Repo.reload!(integration).caldav_sync_tokens ==
               %{path_a => "token-a2", path_b => "token-b-fresh"}
    end

    test "keeps the old token when the fetch that follows fails",
         %{integration: integration, path_a: path_a, path_b: path_b} do
      stub_tier1_server(%{path_a => {:delta, "token-a2"}, path_b => :too_large},
        fresh_token: "token-b-fresh",
        calendar_query: :fail
      )

      run_sync(integration)

      assert Repo.reload!(integration).caldav_sync_tokens[path_b] == "token-b"
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

  defp run_sync(integration) do
    perform_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})
  end

  defp cached_uids(integration) do
    Repo.all(
      from e in ProviderCalendarEventSchema,
        where: e.calendar_integration_id == ^integration.id,
        select: e.uid
    )
  end

  # A Tier 1 server for two paths. `paths` says how each path answers a
  # sync-collection REPORT: `{:delta, new_token}` with its event, `:gone` with
  # a 410, `:too_large` with a body past the delta budget, or `:no_token` when
  # the test expects none to be sent. The sync-token
  # PROPFIND answers `opts[:fresh_token]`, or 500 with `token_probe: :fail`; a
  # calendar-query returns the path's event, or a 500 with
  # `calendar_query: :fail`. Every request is reported to the test process.
  defp stub_tier1_server(paths, opts \\ []) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      path = conn.request_path

      cond do
        conn.method == "PROPFIND" and body =~ "sync-token" ->
          send(test_pid, {:propfind_sync_token, path})

          if opts[:token_probe] == :fail,
            do: Conn.send_resp(conn, 500, "Internal Server Error"),
            else: xml_resp(conn, sync_token_propfind_xml(opts[:fresh_token]))

        body =~ "sync-collection" ->
          send(test_pid, {:sync_collection, path, body})

          case Map.fetch!(paths, path) do
            {:delta, new_token} ->
              xml_resp(conn, sync_collection_xml(event_href(path), event_ical(path), new_token))

            :gone ->
              Conn.send_resp(conn, 410, "Gone")

            :too_large ->
              xml_resp(conn, oversized_delta())
          end

        true ->
          send(test_pid, {:calendar_query, path})

          if opts[:calendar_query] == :fail,
            do: Conn.send_resp(conn, 500, "Internal Server Error"),
            else: respond_to_dual_paths(conn)
      end
    end)
  end

  # The requests the stub reported for `path`, oldest first.
  defp requests_for(path) do
    receive do
      {kind, ^path} -> [kind | requests_for(path)]
      {kind, ^path, _body} -> [kind | requests_for(path)]
    after
      0 -> []
    end
  end

  defp xml_resp(conn, xml) do
    conn
    |> Conn.put_resp_header("content-type", "application/xml")
    |> Conn.send_resp(207, xml)
  end

  defp event_href(path) do
    if path == path1(), do: "#{path}event1.ics", else: "#{path}event2.ics"
  end

  defp event_ical(path), do: if(path == path1(), do: ical_path1(), else: ical_path2())

  # A well-formed delta padded one byte past the budget, so only its size can
  # make the sync refuse it.
  defp oversized_delta do
    xml = sync_collection_xml(event_href(path2()), event_ical(path2()), "token-b2")
    comment = "<!--  -->"
    padding = SyncCollectionReport.max_delta_bytes() - byte_size(xml) - byte_size(comment) + 1
    xml <> "<!-- " <> String.duplicate("x", padding) <> " -->"
  end
end
