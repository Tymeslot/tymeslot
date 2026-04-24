defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsTest do
  use Tymeslot.CalDAVCase, async: false
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

  # ---------------------------------------------------------------------------
  # fetch_events/5
  # ---------------------------------------------------------------------------

  describe "fetch_events/5" do
    test "sends REPORT and returns parsed event maps" do
      xml_response = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/calendars/user/personal/test-event-001.ics</D:href>
          <D:propstat>
            <D:prop>
              <D:getetag>"etag-001"</D:getetag>
              <C:calendar-data>BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:test-event-001@example.com
      DTSTART:20300601T100000Z
      DTEND:20300601T110000Z
      SUMMARY:Integration Test Event
      END:VEVENT
      END:VCALENDAR</C:calendar-data>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "REPORT"

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, xml_response)
      end)

      assert {:ok, [event]} =
               Events.fetch_events(
                 @caldav_client,
                 "/calendars/user/personal/",
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2026-03-01 00:00:00Z],
                 skip_breaker: true
               )

      assert event.uid == "test-event-001@example.com"
      assert event.summary == "Integration Test Event"
    end

    test "accepts 200 OK in addition to the CalDAV-mandated 207 Multi-Status" do
      # Some non-standard servers return 200 for REPORT
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(200, "<D:multistatus xmlns:D=\"DAV:\"/>")
      end)

      assert {:ok, []} =
               Events.fetch_events(
                 @caldav_client,
                 "/calendars/user/personal/",
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2026-03-01 00:00:00Z],
                 skip_breaker: true
               )
    end

    test "sends REPORT to server-root-relative path regardless of base_url path depth" do
      # Verifies no path doubling when base_url contains a CalDAV principal path (Zimbra)
      for base_url <- [
            "https://caldav.example.com/dav/user@example.com",
            "https://caldav.example.com"
          ] do
        ReqTest.stub(:tymeslot_http, fn conn ->
          assert conn.method == "REPORT"
          assert conn.request_path == "/dav/user%40example.com/Calendar/"

          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"/>")
        end)

        client = %{
          base_url: base_url,
          username: "user@example.com",
          password: "pass",
          calendar_paths: ["/dav/user%40example.com/Calendar/"],
          verify_ssl: true,
          provider: :zimbra
        }

        assert {:ok, []} =
                 Events.fetch_events(
                   client,
                   "/dav/user%40example.com/Calendar/",
                   ~U[2026-01-01 00:00:00Z],
                   ~U[2026-03-01 00:00:00Z],
                   skip_breaker: true
                 )
      end
    end

    test "preserves non-standard port when base_url contains a path" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "REPORT"
        assert conn.request_path == "/alice/calendar/"

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"/>")
      end)

      client = %{
        base_url: "https://radicale.example.com:8443/principals/alice",
        username: "alice",
        password: "pass",
        calendar_paths: ["/alice/calendar/"],
        verify_ssl: true,
        provider: :radicale
      }

      assert {:ok, []} =
               Events.fetch_events(
                 client,
                 "/alice/calendar/",
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2026-03-01 00:00:00Z],
                 skip_breaker: true
               )
    end
  end

  # ---------------------------------------------------------------------------
  # create_calendar_event/4
  # ---------------------------------------------------------------------------

  describe "create_calendar_event/4" do
    test "sends PUT to a server-root-relative URL and returns the UID" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        assert String.starts_with?(conn.request_path, "/calendars/user/personal/")

        Conn.send_resp(conn, 201, "")
      end)

      event_data = %{
        summary: "Team meeting",
        start_time: ~U[2026-03-01 10:00:00Z],
        end_time: ~U[2026-03-01 11:00:00Z]
      }

      assert {:ok, uid} =
               Events.create_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 event_data,
                 skip_breaker: true
               )

      assert is_binary(uid)
    end

    test "sends PUT to server-root path when base_url contains a CalDAV path — no path doubling" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        assert String.starts_with?(conn.request_path, "/dav/user%40example.com/Calendar/")
        refute String.contains?(conn.request_path, "/dav/user@example.com/dav/")

        Conn.send_resp(conn, 201, "")
      end)

      client = %{
        base_url: "https://caldav.example.com/dav/user@example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user%40example.com/Calendar/"],
        verify_ssl: true,
        provider: :zimbra
      }

      event_data = %{
        summary: "Test",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert {:ok, _uid} =
               Events.create_calendar_event(
                 client,
                 "/dav/user%40example.com/Calendar/",
                 event_data,
                 skip_breaker: true
               )
    end
  end

  # ---------------------------------------------------------------------------
  # update_calendar_event/5 — ETag-conditional update protocol
  # ---------------------------------------------------------------------------

  describe "update_calendar_event/5" do
    test "sends HEAD then PUT with If-Match from current ETag" do
      stub_sequential(
        fn conn ->
          assert conn.method == "HEAD"

          conn
          |> Conn.put_resp_header("etag", "\"etag-abc\"")
          |> Conn.send_resp(200, "")
        end,
        fn conn ->
          assert conn.method == "PUT"
          [if_match | _rest] = Conn.get_req_header(conn, "if-match")
          assert if_match == "\"etag-abc\""

          Conn.send_resp(conn, 204, "")
        end
      )

      event_data = %{
        summary: "Updated",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "some-uid",
                 event_data,
                 skip_breaker: true
               )
    end

    test "falls back to If-Match: * when HEAD fails" do
      stub_sequential(
        fn conn ->
          assert conn.method == "HEAD"
          Conn.send_resp(conn, 404, "")
        end,
        fn conn ->
          assert conn.method == "PUT"
          assert Conn.get_req_header(conn, "if-match") == ["*"]

          Conn.send_resp(conn, 201, "")
        end
      )

      event_data = %{
        summary: "New event",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "new-uid",
                 event_data,
                 skip_breaker: true
               )
    end

    test "uses supplied etag via opts and skips HEAD" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT",
               "update_calendar_event must not issue HEAD when etag is supplied (got #{conn.method})"

        [if_match | _rest] = Conn.get_req_header(conn, "if-match")
        assert if_match == "\"cached-etag\""

        Conn.send_resp(conn, 204, "")
      end)

      event_data = %{
        summary: "Updated",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "some-uid",
                 event_data,
                 etag: "\"cached-etag\"",
                 skip_breaker: true
               )
    end

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

    test "retries PUT on 502 when If-Match is set" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> Conn.send_resp(conn, 502, "Bad Gateway")
          _second_attempt -> Conn.send_resp(conn, 204, "")
        end
      end)

      event_data = %{
        summary: "Resilient",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert :ok =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "retry-uid",
                 event_data,
                 etag: "\"cached\"",
                 retry_opts: [
                   max_retries: 1,
                   base_delay_ms: 1,
                   max_delay_ms: 5,
                   jitter_factor: 0.0,
                   retryable_errors: [:network_error, :timeout, :server_error]
                 ],
                 skip_breaker: true
               )

      assert :counters.get(counter, 1) == 2
    end

    test "retries PUT with If-Match: * when no ETag is available" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        # HEAD fails → PUT goes unconditional with If-Match: * → safe to retry
        case conn.method do
          "HEAD" ->
            Conn.send_resp(conn, 404, "")

          "PUT" ->
            :counters.add(counter, 1, 1)
            Conn.send_resp(conn, 502, "Bad Gateway")
        end
      end)

      event_data = %{
        summary: "Unconditional",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert {:error, :server_error} =
               Events.update_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "no-etag-uid",
                 event_data,
                 retry_opts: [
                   max_retries: 1,
                   base_delay_ms: 1,
                   max_delay_ms: 5,
                   jitter_factor: 0.0,
                   retryable_errors: [:network_error, :timeout, :server_error]
                 ],
                 skip_breaker: true
               )

      assert :counters.get(counter, 1) == 2
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
            # Retry uses If-Match: * (the "unconditional overwrite" marker)
            assert if_match == ["*"]
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
  end

  # ---------------------------------------------------------------------------
  # delete_calendar_event/4
  # ---------------------------------------------------------------------------

  describe "delete_calendar_event/4" do
    test "sends DELETE and returns :ok on success" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               Events.delete_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "some-uid",
                 skip_breaker: true
               )
    end

    test "returns :ok when event is already gone (idempotent)" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 404, "")
      end)

      assert :ok =
               Events.delete_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "gone-uid",
                 skip_breaker: true
               )
    end

    test "routes DELETE via opts[:provider_event_id] when the event lives on a non-primary calendar" do
      # Regression: a multi-calendar CalDAV integration would previously send
      # DELETE to the FIRST calendar path with the event's UID appended,
      # regardless of which calendar the event actually lives on. The server
      # would return 404 for the (non-existent) URL, which Http.delete_event
      # treats as idempotent success — silently leaving the event intact on
      # its real calendar. Passing the event's real href via opts routes the
      # DELETE to the correct URL.
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:delete_path, conn.request_path})
        Conn.send_resp(conn, 204, "")
      end)

      client_with_two_calendars = %{
        @caldav_client
        | calendar_paths: ["/calendars/user/personal/", "/calendars/user/work/"]
      }

      provider_event_id = "/calendars/user/work/event-on-second-calendar.ics"

      assert :ok =
               Events.delete_calendar_event(
                 client_with_two_calendars,
                 "/calendars/user/personal/",
                 "event-on-second-calendar",
                 skip_breaker: true,
                 provider_event_id: provider_event_id
               )

      assert_receive {:delete_path, ^provider_event_id}
    end

    test "falls back to calendar_path + uid when provider_event_id is missing" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:delete_path, conn.request_path})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               Events.delete_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 "legacy-uid",
                 skip_breaker: true
               )

      assert_receive {:delete_path, "/calendars/user/personal/legacy-uid.ics"}
    end
  end
end
