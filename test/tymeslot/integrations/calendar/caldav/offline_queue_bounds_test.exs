defmodule Tymeslot.Integrations.Calendar.CalDAV.OfflineQueueBoundsTest do
  @moduledoc """
  Covers the bounds on one offline queue flush: where it stops, how many rows
  it replays, and which rows it no longer replays.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.ConfigTestHelpers

  @moduletag :integrations
  @moduletag :calendar

  alias Ecto.Adapters.SQL
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Repo

  @client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/cal/"],
    provider: :caldav
  }

  defp insert_pending_row(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      uid: "queue-event-uid",
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/queue-event-uid.ics",
      summary: "Queued",
      start_at: ~U[2026-04-15 14:00:00.000000Z],
      end_at: ~U[2026-04-15 15:00:00.000000Z],
      all_day: false,
      timezone: "UTC",
      synced_at: ~U[2026-04-15 00:00:00.000000Z],
      etag: "\"cached-etag\""
    }

    insert(:provider_calendar_event, Map.merge(defaults, Map.new(attrs)))
  end

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    integration =
      insert(:calendar_integration,
        provider: "caldav",
        calendar_paths: ["/cal/"]
      )

    {:ok, integration: integration}
  end

  # One stuck server, or one change it will never accept, must not hold the
  # sync job: each row could otherwise wait out its own write timeout.
  describe "flush/2 — bounds" do
    defp count_requests(status) do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        Conn.send_resp(conn, status, "")
      end)

      counter
    end

    test "stops at the first failure that says the server is unreachable",
         %{integration: integration} do
      first =
        insert_pending_row(integration,
          uid: "first",
          provider_event_id: "/cal/first.ics",
          sync_state: "locally_modified"
        )

      second =
        insert_pending_row(integration,
          uid: "second",
          provider_event_id: "/cal/second.ics",
          sync_state: "locally_modified"
        )

      SQL.query!(Repo, "UPDATE provider_calendar_events SET updated_at = $1 WHERE id = $2", [
        ~U[2026-04-14 00:00:00.000000Z],
        first.id
      ])

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:put, conn.request_path})
        Conn.send_resp(conn, 502, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_received {:put, "/cal/first.ics"}
      refute_received {:put, "/cal/second.ics"}
      assert Repo.reload!(first).sync_attempts == 0
      assert Repo.reload!(second).sync_attempts == 0
    end

    test "an outage longer than the attempt cap does not strand a change",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")

      ReqTest.stub(:tymeslot_http, &ReqTest.transport_error(&1, :econnrefused))

      for _cycle <- 1..12 do
        assert :ok = OfflineQueue.flush(integration, @client)
      end

      reloaded = Repo.reload!(row)
      assert reloaded.sync_attempts == 0
      assert %DateTime{} = reloaded.sync_deferred_since

      recovered = count_requests(204)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert :counters.get(recovered, 1) == 1
      assert Repo.reload!(row).sync_state == "synced"
    end

    # Some servers answer a change they cannot parse with a 500, every time.
    # Uncounted, that row would head the queue for good, and every flush
    # would stop at it before reaching the changes queued behind it.
    test "a change the server always fails on stops holding up the ones behind it",
         %{integration: integration} do
      poison =
        insert_pending_row(integration,
          uid: "poison",
          provider_event_id: "/cal/poison.ics",
          sync_state: "locally_modified"
        )

      healthy =
        insert_pending_row(integration,
          uid: "healthy",
          provider_event_id: "/cal/healthy.ics",
          sync_state: "locally_modified"
        )

      SQL.query!(Repo, "UPDATE provider_calendar_events SET updated_at = $1 WHERE id = $2", [
        ~U[2026-04-14 00:00:00.000000Z],
        poison.id
      ])

      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          "/cal/poison.ics" -> Conn.send_resp(conn, 500, "")
          "/cal/healthy.ics" -> Conn.send_resp(conn, 204, "")
        end
      end)

      for _cycle <- 1..11 do
        assert :ok = OfflineQueue.flush(integration, @client)
      end

      assert Repo.reload!(healthy).sync_state == "synced"
      assert Repo.reload!(poison).sync_attempts == 10
    end

    test "a change unanswered for over a day counts each further failure",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")
      ReqTest.stub(:tymeslot_http, &ReqTest.transport_error(&1, :econnrefused))

      assert :ok = OfflineQueue.flush(integration, @client)
      assert Repo.reload!(row).sync_attempts == 0

      SQL.query!(
        Repo,
        "UPDATE provider_calendar_events SET sync_deferred_since = $1 WHERE id = $2",
        [DateTime.add(DateTime.utc_now(), -25, :hour), row.id]
      )

      assert :ok = OfflineQueue.flush(integration, @client)
      assert :ok = OfflineQueue.flush(integration, @client)
      assert Repo.reload!(row).sync_attempts == 2
    end

    # A 503 is a server that is down or in maintenance, which says nothing
    # about whether it would accept the change: counted, an ordinary outage
    # would strand the oldest queued change within hours.
    test "a 503 leaves the change queued without counting the attempt",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")
      count_requests(503)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert %{sync_state: "locally_modified", sync_attempts: 0, sync_deferred_since: %DateTime{}} =
               Repo.reload!(row)
    end

    # A server down for good answers 503 on every cycle; the day's grace
    # covers it as it covers a refused connection.
    test "a change a down server has refused for over a day counts each further failure",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")
      count_requests(503)

      assert :ok = OfflineQueue.flush(integration, @client)
      assert Repo.reload!(row).sync_attempts == 0

      SQL.query!(
        Repo,
        "UPDATE provider_calendar_events SET sync_deferred_since = $1 WHERE id = $2",
        [DateTime.add(DateTime.utc_now(), -25, :hour), row.id]
      )

      assert :ok = OfflineQueue.flush(integration, @client)
      assert Repo.reload!(row).sync_attempts == 1
    end

    test "a change unanswered for under a day does not count", %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")
      ReqTest.stub(:tymeslot_http, &ReqTest.transport_error(&1, :econnrefused))

      SQL.query!(
        Repo,
        "UPDATE provider_calendar_events SET sync_deferred_since = $1 WHERE id = $2",
        [DateTime.add(DateTime.utc_now(), -23, :hour), row.id]
      )

      assert :ok = OfflineQueue.flush(integration, @client)
      assert Repo.reload!(row).sync_attempts == 0
    end

    # The day is counted from the first of an unbroken run of unanswered
    # attempts: an answer from the server ends the run.
    test "an answer from the server starts the day again", %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")

      SQL.query!(
        Repo,
        "UPDATE provider_calendar_events SET sync_deferred_since = $1 WHERE id = $2",
        [DateTime.add(DateTime.utc_now(), -25, :hour), row.id]
      )

      count_requests(403)
      assert :ok = OfflineQueue.flush(integration, @client)
      assert %{sync_attempts: 1, sync_deferred_since: nil} = Repo.reload!(row)

      ReqTest.stub(:tymeslot_http, &ReqTest.transport_error(&1, :econnrefused))
      assert :ok = OfflineQueue.flush(integration, @client)
      assert %{sync_attempts: 1, sync_deferred_since: %DateTime{}} = Repo.reload!(row)
    end

    test "counts a refusal towards the cap", %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")

      count_requests(403)

      assert :ok = OfflineQueue.flush(integration, @client)
      assert Repo.reload!(row).sync_attempts == 1
    end

    test "carries on past a change the server refuses", %{integration: integration} do
      insert_pending_row(integration, uid: "first", sync_state: "locally_modified")
      insert_pending_row(integration, uid: "second", sync_state: "locally_modified")

      counter = count_requests(403)

      assert :ok = OfflineQueue.flush(integration, @client)
      assert :counters.get(counter, 1) == 2
    end

    test "replays at most 50 rows in one flush", %{integration: integration} do
      for n <- 1..51 do
        insert_pending_row(integration, uid: "row-#{n}", sync_state: "locally_modified")
      end

      counter = count_requests(204)

      assert :ok = OfflineQueue.flush(integration, @client)
      assert :counters.get(counter, 1) == 50
    end

    test "no longer replays a row that has failed ten times", %{integration: integration} do
      spent =
        insert_pending_row(integration,
          uid: "spent",
          sync_state: "locally_modified",
          sync_attempts: 10,
          sync_last_error: "The calendar server refused the change."
        )

      counter = count_requests(204)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert :counters.get(counter, 1) == 0
      reloaded = Repo.reload!(spent)
      assert reloaded.sync_state == "locally_modified"
      assert reloaded.sync_last_error == "The calendar server refused the change."
    end
  end
end
