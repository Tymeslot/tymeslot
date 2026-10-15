defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsEtagProbeTest do
  @moduledoc """
  How an update with no cached ETag finds one, and what a refused
  `If-Match: *` is taken to mean.

  Split from `EventsTest` for the servers that do not answer the ordinary
  probe: iCloud refuses HEAD on an event resource with 400 and refuses
  `If-Match: *` with 412 on an event it holds (issue #158).
  """
  use Tymeslot.HttpTransportCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.{ConditionalWrite, Events}

  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/calendars/user/personal/"],
    verify_ssl: true,
    provider: :caldav
  }

  @stored_event """
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:stored
  DTSTART:20260224T100000Z
  DTEND:20260224T110000Z
  SUMMARY:Stored
  END:VEVENT
  END:VCALENDAR
  """

  describe "update_calendar_event/5 without a cached ETag" do
    test "reports an absent event as :not_found when If-Match: * is rejected" do
      # The event is gone from the server (never created, or deleted in the
      # organiser's own client). HEAD 404s, so we fall back to `If-Match: *`,
      # which the server rejects with 412 because it holds no representation.
      # That is absence, not a conflict: reporting :not_found is what lets
      # CalendarEventSync recreate the booking's event. Reporting
      # :precondition_failed instead left the calendar permanently empty.
      # A GET confirms the absence first, since not every server keeps to
      # the meaning of a refused `If-Match: *`.
      stub_ordered([
        fn conn ->
          assert conn.method == "HEAD"
          Conn.send_resp(conn, 404, "")
        end,
        fn conn ->
          assert conn.method == "PUT"
          assert Conn.get_req_header(conn, "if-match") == ["*"]

          Conn.send_resp(conn, 412, "")
        end,
        fn conn ->
          assert conn.method == "GET"
          Conn.send_resp(conn, 404, "")
        end
      ])

      event_data = %{
        summary: "Booking that never landed",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert {:error, :not_found} =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "absent-uid",
                 event_data,
                 skip_breaker: true
               )
    end

    # Issue #158: iCloud answers HEAD on an event resource with 400 but
    # serves a GET on the same URL with its ETag.
    test "reads the ETag with a GET when the server refuses HEAD" do
      stub_ordered([
        fn conn ->
          assert conn.method == "HEAD"
          Conn.send_resp(conn, 400, "")
        end,
        fn conn ->
          assert conn.method == "GET"

          conn
          |> Conn.put_resp_header("etag", "\"from-get\"")
          |> Conn.send_resp(200, @stored_event)
        end,
        fn conn ->
          assert conn.method == "PUT"
          assert Conn.get_req_header(conn, "if-match") == [~s("from-get")]
          Conn.send_resp(conn, 204, "")
        end
      ])

      assert :ok = update_without_etag("head-refused-uid")
    end

    # A server too slow to answer HEAD is too slow to answer a GET: the
    # probe gives up and the write goes out without an ETag.
    for {label, error} <- [{"times out", :timeout}, {"fails in transport", :econnrefused}] do
      test "writes without an ETag and sends no GET when HEAD #{label}" do
        error = unquote(error)

        stub_ordered([
          fn conn ->
            assert conn.method == "HEAD"
            ReqTest.transport_error(conn, error)
          end,
          fn conn ->
            assert conn.method == "PUT"
            assert Conn.get_req_header(conn, "if-match") == ["*"]
            Conn.send_resp(conn, 204, "")
          end
        ])

        assert :ok = update_without_etag("head-#{error}-uid")
      end
    end

    test "sends no GET when HEAD reports the event gone" do
      stub_ordered([
        fn conn ->
          assert conn.method == "HEAD"
          Conn.send_resp(conn, 410, "")
        end,
        fn conn ->
          assert conn.method == "PUT"
          assert Conn.get_req_header(conn, "if-match") == ["*"]
          Conn.send_resp(conn, 204, "")
        end
      ])

      assert :ok = update_without_etag("head-gone-uid")
    end

    # HEAD and GET share the probe's time. The HEAD here answers after all of
    # it is spent, so no GET follows.
    test "sends no GET when a refused HEAD has used up the probe's time" do
      stub_ordered([
        fn conn ->
          assert conn.method == "HEAD"
          receive after: (60 -> :ok)
          Conn.send_resp(conn, 400, "")
        end,
        fn conn ->
          assert conn.method == "PUT"
          assert Conn.get_req_header(conn, "if-match") == ["*"]
          Conn.send_resp(conn, 204, "")
        end
      ])

      assert :ok = update_without_etag("slow-refusal-uid", head_timeout: 50)
    end

    # iCloud also refuses `If-Match: *` with 412 on an event it holds, which
    # used to be read as absence and sent the update into a recreate.
    test "writes under the server's ETag when If-Match: * is refused on an existing event" do
      stub_ordered([
        fn conn ->
          assert conn.method == "HEAD"
          Conn.send_resp(conn, 400, "")
        end,
        fn conn ->
          assert conn.method == "GET"
          Conn.send_resp(conn, 503, "")
        end,
        fn conn ->
          assert Conn.get_req_header(conn, "if-match") == ["*"]
          Conn.send_resp(conn, 412, "")
        end,
        fn conn ->
          assert conn.method == "GET"

          conn
          |> Conn.put_resp_header("etag", "\"current\"")
          |> Conn.send_resp(200, @stored_event)
        end,
        fn conn ->
          assert conn.method == "PUT"
          assert Conn.get_req_header(conn, "if-match") == [~s("current")]
          Conn.send_resp(conn, 204, "")
        end
      ])

      assert :ok = update_without_etag("wildcard-refused-uid")
    end

    test "overwrites unconditionally when the existing event comes with no ETag at all" do
      stub_ordered([
        fn conn ->
          assert conn.method == "HEAD"
          Conn.send_resp(conn, 200, "")
        end,
        fn conn ->
          assert conn.method == "GET"
          Conn.send_resp(conn, 200, @stored_event)
        end,
        fn conn ->
          assert Conn.get_req_header(conn, "if-match") == ["*"]
          Conn.send_resp(conn, 412, "")
        end,
        fn conn ->
          assert conn.method == "GET"
          Conn.send_resp(conn, 200, @stored_event)
        end,
        fn conn ->
          assert conn.method == "PUT"
          assert Conn.get_req_header(conn, "if-match") == []
          assert Conn.get_req_header(conn, "if-none-match") == []
          Conn.send_resp(conn, 204, "")
        end
      ])

      assert :ok = update_without_etag("etagless-uid")
    end
  end

  # Every request of one update shares a deadline, so the chain ends inside
  # the calendar worker's time limit rather than being killed there.
  describe "update_calendar_event/5 under a deadline" do
    test "sends nothing further once the deadline has passed" do
      stub_ordered([
        fn conn ->
          assert conn.method == "HEAD"
          Conn.send_resp(conn, 404, "")
        end,
        fn conn ->
          assert conn.method == "PUT"
          receive after: (60 -> :ok)
          Conn.send_resp(conn, 412, "")
        end
      ])

      deadline = System.monotonic_time(:millisecond) + 50

      assert {:error, :timeout} = update_without_etag("late-uid", deadline: deadline)
    end

    test "starts no request at all with no time left" do
      stub_ordered([])

      deadline = System.monotonic_time(:millisecond)

      assert {:error, :timeout} = update_without_etag("expired-uid", deadline: deadline)
    end
  end

  describe "ConditionalWrite.with_deadline/1" do
    test "gives the update less than the calendar worker's 90 seconds" do
      before = System.monotonic_time(:millisecond)
      deadline = Keyword.fetch!(ConditionalWrite.with_deadline([]), :deadline)

      assert deadline - before >= 60_000
      assert deadline - before < 90_000
    end

    test "keeps a deadline the caller already started" do
      assert ConditionalWrite.with_deadline(deadline: 123)[:deadline] == 123
    end
  end

  # Answers each request with the next handler, and fails on any request
  # beyond the last, so a test pins the whole exchange rather than its start.
  defp stub_ordered(handlers) do
    counter = :counters.new(1, [:atomics])

    ReqTest.stub(:tymeslot_http, fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      case Enum.at(handlers, n - 1) do
        nil -> flunk("unexpected request #{n}: #{conn.method}")
        handler -> handler.(conn)
      end
    end)

    on_exit(fn -> assert :counters.get(counter, 1) == length(handlers) end)
  end

  defp update_without_etag(uid, opts \\ []) do
    Events.update_calendar_event(
      @caldav_client,
      "/calendars/user/personal/",
      uid,
      %{
        summary: "Rescheduled",
        start_time: ~U[2026-02-24 12:00:00Z],
        end_time: ~U[2026-02-24 13:00:00Z]
      },
      Keyword.put(opts, :skip_breaker, true)
    )
  end
end
