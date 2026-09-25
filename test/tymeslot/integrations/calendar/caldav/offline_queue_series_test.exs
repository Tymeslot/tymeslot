defmodule Tymeslot.Integrations.Calendar.CalDAV.OfflineQueueSeriesTest do
  @moduledoc """
  Covers the offline queue's refusal to replay an update or delete of a row
  that belongs to a repeating series.

  A CalDAV series is one resource: an update of any occurrence is patched
  onto the master VEVENT and a delete removes the resource, so replaying
  either rewrites or removes every occurrence. Rows queued before the grid
  refused such writes must stay queued, visibly, and never reach the server.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.ConfigTestHelpers

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :unit

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Repo
  alias Tymeslot.Test.LogCapture

  @client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/cal/"],
    verify_ssl: true,
    provider: :caldav
  }

  @series_message "This change was made to one occurrence of a repeating event, and the calendar server would have applied it to every occurrence, so it was not sent."

  defp assert_skipped(row, sync_state) do
    reloaded = Repo.reload!(row)

    assert reloaded.sync_state == sync_state
    assert reloaded.sync_attempts == 1
    assert reloaded.sync_last_error == @series_message
  end

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

    ReqTest.stub(:tymeslot_http, fn conn ->
      flunk("a series write must never reach the calendar server, got #{conn.method}")
    end)

    {:ok, integration: integration}
  end

  describe "flush/2 — rows that belong to a repeating series" do
    test "skips an update of an occurrence that carries the series' rule",
         %{integration: integration} do
      row =
        insert_pending_row(integration,
          sync_state: "locally_modified",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
        )

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_skipped(row, "locally_modified")
    end

    # An occurrence edited on its own has no RRULE; only the recurrence id the
    # sync keeps in `provider_metadata` marks it as part of the series.
    test "skips an update of an override known only by its recurrence id",
         %{integration: integration} do
      row =
        insert_pending_row(integration,
          sync_state: "locally_modified",
          provider_metadata: %{"recurrence_id" => "20260415T140000Z"}
        )

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_skipped(row, "locally_modified")
    end

    test "skips a delete of an occurrence that carries the series' rule",
         %{integration: integration} do
      row =
        insert_pending_row(integration,
          sync_state: "locally_deleted",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
        )

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_skipped(row, "locally_deleted")
    end

    test "skips a delete of an override known only by its recurrence id",
         %{integration: integration} do
      row =
        insert_pending_row(integration,
          sync_state: "locally_deleted",
          provider_metadata: %{"recurrence_id" => "20260415T140000Z"}
        )

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_skipped(row, "locally_deleted")
    end

    test "logs the skipped row's uid so it can be inspected",
         %{integration: integration} do
      LogCapture.attach()

      insert_pending_row(integration,
        uid: "series-occurrence-uid",
        provider_event_id: "/cal/series-occurrence-uid.ics",
        sync_state: "locally_modified",
        recurrence_rule: "FREQ=DAILY"
      )

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_receive {:captured_log,
                      %{level: :warning, meta: %{uid: "series-occurrence-uid"} = meta}}

      assert meta.reason == :recurring_event
      assert meta.sync_state == "locally_modified"
    end

    test "still replays the single events queued alongside a skipped one",
         %{integration: integration} do
      insert_pending_row(integration,
        uid: "series-uid",
        provider_event_id: "/cal/series-uid.ics",
        sync_state: "locally_modified",
        recurrence_rule: "FREQ=WEEKLY"
      )

      single =
        insert_pending_row(integration,
          uid: "single-uid",
          provider_event_id: "/cal/single-uid.ics",
          sync_state: "locally_modified"
        )

      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/cal/single-uid.ics"
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert Repo.reload!(single).sync_state == "synced"
    end
  end
end
