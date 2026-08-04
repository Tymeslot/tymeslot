defmodule Tymeslot.Integrations.Calendar.CalDAV.OfflineQueueTest do
  @moduledoc """
  Covers the offline write queue that replays locally-modified cache
  rows against the remote CalDAV server at the start of every sync
  cycle.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.ConfigTestHelpers

  @moduletag :integrations
  @moduletag :unit

  alias Ecto.Adapters.SQL
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/cal/"],
    verify_ssl: true,
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

  describe "flush/2 — locally_modified rows" do
    test "PUTs with the cached ETag and marks the row synced on 204",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")

      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        [if_match | _rest] = Conn.get_req_header(conn, "if-match")
        assert if_match == "\"cached-etag\""
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      reloaded = Repo.reload!(row)
      assert reloaded.sync_state == "synced"
      assert reloaded.sync_attempts == 0
      assert is_nil(reloaded.sync_last_error)
    end

    test "increments sync_attempts and stays queued on 502",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 502, "Bad Gateway")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      reloaded = Repo.reload!(row)
      assert reloaded.sync_state == "locally_modified"
      assert reloaded.sync_attempts == 1

      # `sync_last_error` is a human-readable field, not a dump of the internal
      # error term: an inspected atom such as `":server_error"` must never
      # reach it.
      assert reloaded.sync_last_error ==
               "The calendar server reported an error. Tymeslot will retry automatically."

      refute reloaded.sync_last_error =~ ":server_error"
    end

    test "records a human-readable message when the server rejects the credentials",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "Unauthorized")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      reloaded = Repo.reload!(row)

      assert reloaded.sync_last_error ==
               "The calendar server rejected the stored credentials. Please reconnect the calendar."

      refute reloaded.sync_last_error =~ ":unauthorized"
    end

    test "force-overwrites on 412 for a Tymeslot-owned event (keep_local)",
         %{integration: integration} do
      row =
        insert_pending_row(integration,
          sync_state: "locally_modified",
          created_by_tymeslot: true
        )

      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        if_match = Conn.get_req_header(conn, "if-match")

        case attempt do
          1 ->
            assert if_match == ["\"cached-etag\""]
            Conn.send_resp(conn, 412, "Precondition Failed")

          2 ->
            # A forced overwrite carries no condition at all.
            assert if_match == []
            Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      reloaded = Repo.reload!(row)
      assert reloaded.sync_state == "synced"
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "flush/2 — locally_deleted rows" do
    test "issues DELETE and drops the cache row on success",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_deleted")

      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      refute Repo.get(ProviderCalendarEventSchema, row.id)
    end

    test "treats 404 as already-deleted and drops the cache row",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_deleted")

      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 404, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      refute Repo.get(ProviderCalendarEventSchema, row.id)
    end
  end

  describe "flush/2 — all-day rows" do
    test "replays an all-day row using its dates, not its null timestamps",
         %{integration: integration} do
      row =
        insert_pending_row(integration,
          sync_state: "locally_created",
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-04-15],
          end_date: ~D[2026-04-16]
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "DTSTART;VALUE=DATE:20260415"
        assert body =~ "DTEND;VALUE=DATE:20260416"

        Conn.send_resp(conn, 201, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert Repo.reload!(row).sync_state == "synced"
    end
  end

  describe "flush/2 — rows that can never be sent" do
    test "skips a row with no usable start or end time", %{integration: integration} do
      row =
        insert_pending_row(integration,
          sync_state: "locally_created",
          all_day: false,
          start_at: nil,
          end_at: nil
        )

      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("a row with no start time must never reach the calendar server")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      reloaded = Repo.reload!(row)

      assert reloaded.sync_last_error ==
               "This change is missing the event's start or end time, so it could not be sent to the calendar server."
    end

    # `flush/2` runs before the remote fetch, so a row that raises here used to
    # take down the whole sync job — blocking every other queued change and the
    # integration's own remote sync behind it, on every cycle.
    test "does not stop the rest of the queue from replaying", %{integration: integration} do
      insert_pending_row(integration,
        uid: "unsendable-uid",
        provider_event_id: "/cal/unsendable-uid.ics",
        sync_state: "locally_created",
        start_at: nil,
        end_at: nil
      )

      sendable =
        insert_pending_row(integration,
          uid: "sendable-uid",
          provider_event_id: "/cal/sendable-uid.ics",
          sync_state: "locally_created"
        )

      ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 201, "") end)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert Repo.reload!(sendable).sync_state == "synced"
    end
  end

  describe "flush/2 — empty queue" do
    test "is a no-op when no rows are pending", %{integration: integration} do
      # All rows are synced — no HTTP traffic should happen.
      _row = insert_pending_row(integration, sync_state: "synced")

      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("OfflineQueue.flush must not touch the network when queue is empty")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)
    end

    test "ignores rows belonging to other integrations", %{integration: integration} do
      # A row on another integration must not be flushed.
      other = insert(:calendar_integration, provider: "caldav", calendar_paths: ["/cal/"])
      _row = insert_pending_row(other, sync_state: "locally_modified")

      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("OfflineQueue.flush touched network for rows belonging to another integration")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)
    end
  end

  describe "query helpers" do
    test "list_pending returns non-synced rows in updated_at order",
         %{integration: integration} do
      older = insert_pending_row(integration, uid: "older", sync_state: "locally_modified")
      _synced = insert_pending_row(integration, uid: "synced-1", sync_state: "synced")
      newer = insert_pending_row(integration, uid: "newer", sync_state: "locally_created")

      # Force an ordering difference independent of insert order
      SQL.query!(
        Repo,
        "UPDATE provider_calendar_events SET updated_at = $1 WHERE id = $2",
        [~U[2026-04-14 00:00:00.000000Z], older.id]
      )

      SQL.query!(
        Repo,
        "UPDATE provider_calendar_events SET updated_at = $1 WHERE id = $2",
        [~U[2026-04-15 00:00:00.000000Z], newer.id]
      )

      uids =
        integration.id
        |> ProviderCalendarEventQueries.list_pending()
        |> Enum.map(& &1.uid)

      assert uids == ["older", "newer"]
    end

    test "mark_synced clears queue fields and updates etag",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified", etag: "\"stale\"")

      assert {:ok, :updated} =
               ProviderCalendarEventQueries.mark_synced(integration.id, row.uid, "\"fresh\"")

      reloaded = Repo.reload!(row)
      assert reloaded.sync_state == "synced"
      assert reloaded.sync_attempts == 0
      assert reloaded.sync_last_error == nil
      assert reloaded.etag == "\"fresh\""
    end

    test "mark_sync_failed increments sync_attempts and sets sync_last_error without changing sync_state",
         %{integration: integration} do
      row = insert_pending_row(integration, sync_state: "locally_modified")

      assert :ok =
               ProviderCalendarEventQueries.mark_sync_failed(
                 integration.id,
                 row.uid,
                 "502 Bad Gateway"
               )

      after_first = Repo.reload!(row)
      assert after_first.sync_state == "locally_modified"
      assert after_first.sync_attempts == 1
      assert after_first.sync_last_error == "502 Bad Gateway"

      assert :ok =
               ProviderCalendarEventQueries.mark_sync_failed(
                 integration.id,
                 row.uid,
                 "503 Service Unavailable"
               )

      after_second = Repo.reload!(row)
      assert after_second.sync_state == "locally_modified"
      assert after_second.sync_attempts == 2
      assert after_second.sync_last_error == "503 Service Unavailable"
    end

    test "upsert_queue_entry applies on-conflict update — second call's sync_state wins",
         %{integration: integration} do
      base_attrs = %{
        calendar_integration_id: integration.id,
        uid: "upsert-test-uid",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/upsert-test-uid.ics",
        summary: "Upsert Test",
        start_at: ~U[2026-04-15 14:00:00.000000Z],
        end_at: ~U[2026-04-15 15:00:00.000000Z],
        all_day: false,
        timezone: "UTC",
        synced_at: ~U[2026-04-15 00:00:00.000000Z],
        etag: "\"etag-v1\"",
        sync_state: "locally_created"
      }

      assert {:ok, 1} = ProviderCalendarEventQueries.upsert_queue_entry(base_attrs)

      first =
        Repo.get_by!(ProviderCalendarEventSchema,
          uid: "upsert-test-uid",
          calendar_integration_id: integration.id
        )

      assert first.sync_state == "locally_created"

      updated_attrs = Map.put(base_attrs, :sync_state, "locally_modified")
      assert {:ok, 1} = ProviderCalendarEventQueries.upsert_queue_entry(updated_attrs)

      second =
        Repo.get_by!(ProviderCalendarEventSchema,
          uid: "upsert-test-uid",
          calendar_integration_id: integration.id
        )

      assert second.sync_state == "locally_modified"
    end
  end
end
