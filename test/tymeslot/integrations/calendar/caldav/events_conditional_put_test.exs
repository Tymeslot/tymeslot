defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsConditionalPutTest do
  @moduledoc """
  What happens when a CalDAV server rejects the precondition on an update.

  Split from `EventsTest`, which covers how the ETag is resolved and how
  transient failures are retried; this module covers only what the caller
  gets back once the server has refused the conditional write.
  """
  use Tymeslot.HttpTransportCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.Events

  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/calendars/user/personal/"],
    verify_ssl: true,
    provider: :caldav
  }

  describe "update_calendar_event/5 — rejected preconditions" do
    test "returns :precondition_failed on 412 with default :fail policy" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.method do
          "HEAD" ->
            conn
            |> Conn.put_resp_header("etag", "\"old-etag\"")
            |> Conn.send_resp(200, "")

          "PUT" ->
            # Server has a newer version — conditional check fails
            Conn.send_resp(conn, 412, "Precondition Failed")
        end
      end)

      event_data = %{
        summary: "Conflict",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert {:error, :precondition_failed} =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "conflict-uid",
                 event_data,
                 skip_breaker: true
               )
    end

    test "conflict_resolution :keep_server swallows 412 and returns :ok" do
      # etag is supplied so HEAD is skipped; exactly one PUT should be issued
      # (the conflict resolution swallows the 412 without a retry)
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        assert conn.method == "PUT"
        Conn.send_resp(conn, 412, "Precondition Failed")
      end)

      event_data = %{
        summary: "Conflict",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "conflict-uid",
                 event_data,
                 etag: "\"stale\"",
                 conflict_resolution: :keep_server,
                 skip_breaker: true
               )

      assert :counters.get(counter, 1) == 1
    end

    test "conflict_resolution :keep_local retries without If-Match after 412" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        if_match = Conn.get_req_header(conn, "if-match")

        case attempt do
          1 ->
            assert if_match == ["\"stale\""]
            Conn.send_resp(conn, 412, "Precondition Failed")

          2 ->
            # Forcing the local version through means no condition at all —
            # If-Match: * would still assert the resource exists.
            assert if_match == []
            Conn.send_resp(conn, 204, "")
        end
      end)

      event_data = %{
        summary: "Override",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "owned-uid",
                 event_data,
                 etag: "\"stale\"",
                 conflict_resolution: :keep_local,
                 skip_breaker: true
               )

      assert :counters.get(counter, 1) == 2
    end

    test "replays unconditionally when the server answers If-Match: * with 409" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.method do
          # No cached ETag, and this server refuses HEAD outright.
          "HEAD" ->
            Conn.send_resp(conn, 501, "")

          "PUT" ->
            :counters.add(counter, 1, 1)
            attempt = :counters.get(counter, 1)
            if_match = Conn.get_req_header(conn, "if-match")

            case attempt do
              1 ->
                assert if_match == ["*"]
                Conn.send_resp(conn, 409, "Conflict")

              2 ->
                assert if_match == []
                Conn.send_resp(conn, 204, "")
            end
        end
      end)

      event_data = %{
        summary: "Booking updated",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "owned-uid",
                 event_data,
                 skip_breaker: true
               )

      assert :counters.get(counter, 1) == 2
    end

    test "a 409 against a real ETag follows the conflict policy instead of forcing" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        :counters.add(counter, 1, 1)
        assert Conn.get_req_header(conn, "if-match") == ["\"live\""]
        Conn.send_resp(conn, 409, "Conflict")
      end)

      event_data = %{
        summary: "Booking updated",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert {:error, :precondition_failed} =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "owned-uid",
                 event_data,
                 etag: "\"live\"",
                 conflict_resolution: :fail,
                 skip_breaker: true
               )

      # The ETag carried a real guarantee, so the write is never forced through.
      assert :counters.get(counter, 1) == 1
    end
  end
end
