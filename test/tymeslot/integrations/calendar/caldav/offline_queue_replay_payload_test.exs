defmodule Tymeslot.Integrations.Calendar.CalDAV.OfflineQueueReplayPayloadTest do
  @moduledoc """
  How much of a queued CalDAV row the offline replay sends: the whole event
  for a create, and a synced document's stored alarms left untouched.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.ConfigTestHelpers

  @moduletag :integrations
  @moduletag :unit

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue

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

  describe "flush/2 — how much of the event the replay sends" do
    # The rebuilt payload used to carry a narrow subset of the row, so a
    # replayed write of a recurring event replaced the whole series on the
    # server with one non-recurring VEVENT carrying no attendees and no alarms.
    # A create is the replay that still sends a series; an update of one is
    # refused, see `OfflineQueueSeriesTest`.
    test "a replayed create still carries the RRULE, attendees and alarms",
         %{integration: integration} do
      insert_pending_row(integration,
        sync_state: "locally_created",
        raw_ical: nil,
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
        attendees: [%{"email" => "sam@example.com", "display_name" => "Sam"}],
        reminders: [%{"method" => "popup", "minutes_before" => 15}]
      )

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        assert body =~ "RRULE:FREQ=WEEKLY;BYDAY=MO"
        assert body =~ "sam@example.com"
        assert body =~ "BEGIN:VALARM"

        Conn.send_resp(conn, 201, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)
    end

    # The sync never reads VALARMs, so a row holding the server's document
    # says `reminders: []` whatever alarms it has; replaying that list made
    # the patcher delete every one of them.
    test "a replayed update of a synced document keeps its stored alarm",
         %{integration: integration} do
      insert_pending_row(integration,
        sync_state: "locally_modified",
        summary: "Renamed",
        reminders: [],
        raw_ical: document_with_alarm()
      )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:put_body, body})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_received {:put_body, body}
      assert body =~ "SUMMARY:Renamed"
      assert body =~ "BEGIN:VALARM\r\nTRIGGER:-P1D\r\nACTION:DISPLAY\r\nEND:VALARM"
    end

    test "a replayed update carrying reminders a local edit set writes them",
         %{integration: integration} do
      insert_pending_row(integration,
        sync_state: "locally_modified",
        reminders: [%{"method" => "popup", "minutes_before" => 10}],
        raw_ical: document_with_alarm()
      )

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:put_body, body})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_received {:put_body, body}
      assert body =~ "TRIGGER:-PT10M"
      refute body =~ "TRIGGER:-P1D"
    end
  end

  defp document_with_alarm do
    """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Example//Other client//EN\r
    BEGIN:VEVENT\r
    UID:queue-event-uid\r
    DTSTAMP:20260401T090000Z\r
    DTSTART:20260415T140000Z\r
    DTEND:20260415T150000Z\r
    SUMMARY:Queued\r
    BEGIN:VALARM\r
    TRIGGER:-P1D\r
    ACTION:DISPLAY\r
    END:VALARM\r
    END:VEVENT\r
    END:VCALENDAR\r
    """
  end
end
