defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsConditionalPutTest do
  @moduledoc """
  What happens when a CalDAV server rejects the precondition on an update.

  Split from `EventsTest`, which covers how the ETag is resolved and how
  transient failures are retried; this module covers only the precondition
  itself: how it is put on the wire, and what the caller gets back once the
  server has refused it.
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

  # `If-Match` takes a quoted entity-tag (RFC 9110 section 8.8.3), but a cached
  # ETag is stored unquoted so that the same tag compares equal however a server
  # spells it. A create now caches one of those the moment the event is written,
  # so the requoting is what stands between the next conditional write and a
  # malformed precondition the server can only answer 412 to, which reads
  # exactly like a genuine conflict.
  describe "update_calendar_event/5: the precondition's wire form" do
    test "quotes a cached ETag that reached us with its quotes stripped" do
      assert capture_if_match(etag: "abc123") == [~s("abc123")]
    end

    test "leaves a tag that is already in wire form alone" do
      assert capture_if_match(etag: ~s("abc123")) == [~s("abc123")]
    end

    test "keeps a weak tag's prefix outside the quotes" do
      assert capture_if_match(etag: "W/abc123") == [~s(W/"abc123")]
    end

    defp capture_if_match(opts) do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        send(test_pid, {:if_match, Conn.get_req_header(conn, "if-match")})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "wire-form-uid",
                 %{
                   summary: "Precondition",
                   start_time: ~U[2026-02-24 10:00:00Z],
                   end_time: ~U[2026-02-24 11:00:00Z]
                 },
                 Keyword.merge([skip_breaker: true], opts)
               )

      assert_received {:if_match, if_match}
      if_match
    end
  end

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

  describe "conditional PUT If-Match" do
    # Regression: `provider_calendar_events.etag` is stored with its quotes
    # stripped (so the same tag compares equal however a server spells it), and
    # the colour write-back passes that stored value straight through. It was
    # sent as a bare token, which is not a valid entity-tag, so the server
    # failed the precondition and the write was reported back as a conflict —
    # the user's change silently reverted.
    test "re-quotes a cached ETag that was stored without its quotes" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:if_match, Conn.get_req_header(conn, "if-match")})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "some-uid",
                 %{
                   summary: "Updated",
                   start_time: ~U[2026-02-24 10:00:00Z],
                   end_time: ~U[2026-02-24 11:00:00Z]
                 },
                 etag: "92c6b31c8ed79bea274b1c79fe2f80a8",
                 skip_breaker: true
               )

      assert_receive {:if_match, ["\"92c6b31c8ed79bea274b1c79fe2f80a8\""]}
    end

    test "leaves an already-quoted ETag alone" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:if_match, Conn.get_req_header(conn, "if-match")})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "some-uid",
                 %{
                   summary: "Updated",
                   start_time: ~U[2026-02-24 10:00:00Z],
                   end_time: ~U[2026-02-24 11:00:00Z]
                 },
                 etag: "\"already-quoted\"",
                 skip_breaker: true
               )

      assert_receive {:if_match, ["\"already-quoted\""]}
    end

    test "keeps the weak-comparison prefix when re-quoting" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:if_match, Conn.get_req_header(conn, "if-match")})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "some-uid",
                 %{
                   summary: "Updated",
                   start_time: ~U[2026-02-24 10:00:00Z],
                   end_time: ~U[2026-02-24 11:00:00Z]
                 },
                 etag: "W/\"weak-tag",
                 skip_breaker: true
               )

      assert_receive {:if_match, ["W/\"weak-tag\""]}
    end
  end
end
