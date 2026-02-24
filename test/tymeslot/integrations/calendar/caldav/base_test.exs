defmodule Tymeslot.Integrations.Calendar.CalDAV.BaseTest do
  use Tymeslot.CalDAVCase, async: false
  @moduletag :integrations

  # Common client fixtures used across multiple tests.
  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: [],
    provider: :caldav
  }

  @caldav_client_with_paths %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/calendars/user/personal/"],
    provider: :caldav
  }

  # These tests exercise the real HTTPClient → Req → Req.Test path so that
  # transport-level bugs (method normalisation, header building, option assembly)
  # are caught automatically.  The global test config points :http_client_module
  # at HTTPClientMock; CalDAVCase overrides it to use the real HTTPClient.

  describe "propfind/4" do
    test "routes PROPFIND through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PROPFIND"
        assert conn.request_path == "/calendars/user/"

        [auth | _rest] = Conn.get_req_header(conn, "authorization")
        assert String.starts_with?(auth, "Basic ")

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<xml/>")
      end)

      assert {:ok, %Req.Response{status: 207}} =
               Base.propfind("https://caldav.example.com/calendars/user/", "user", "pass")
    end

    test "returns :unauthorized on 401 response" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} =
               Base.propfind("https://caldav.example.com/calendars/user/", "user", "bad_pass")
    end
  end

  describe "report/5" do
    test "routes REPORT through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "REPORT"
        assert conn.request_path == "/calendars/user/personal/"

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<xml/>")
      end)

      assert {:ok, %Req.Response{status: 207}} =
               Base.report(
                 "https://caldav.example.com/calendars/user/personal/",
                 "user",
                 "pass",
                 "<calendar-query/>"
               )
    end

    test "maps transport timeout to :timeout" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        ReqTest.transport_error(conn, :timeout)
      end)

      assert {:error, :timeout} =
               Base.report(
                 "https://caldav.example.com/calendars/user/personal/",
                 "user",
                 "pass",
                 "<calendar-query/>"
               )
    end
  end

  describe "put_event/5" do
    test "routes PUT through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/calendars/user/personal/event.ics"

        Conn.send_resp(conn, 201, "")
      end)

      assert {:ok, _response} =
               Base.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR"
               )
    end
  end

  describe "delete_event/4" do
    test "routes DELETE through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/calendars/user/personal/event.ics"

        Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, _response} =
               Base.delete_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end
  end

  describe "head_event/4" do
    test "routes HEAD through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "HEAD"
        assert conn.request_path == "/calendars/user/personal/event.ics"

        conn
        |> Conn.put_resp_header("etag", "\"abc123\"")
        |> Conn.send_resp(200, "")
      end)

      assert {:ok, _response} =
               Base.head_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end
  end

  # RFC 4791 discovery fallback tests
  # When the guessed discovery path fails (e.g., /calendars/{user}/ on Zimbra),
  # Base falls back to current-user-principal → calendar-home-set discovery.

  describe "RFC 4791 discovery fallback" do
    test "test_connection succeeds via current-user-principal when discovery path is not found" do
      # First call: discovery path → 404
      # Second call: RFC 4791 probe to / → 207
      stub_sequential(
        fn conn -> Conn.send_resp(conn, 404, "") end,
        fn conn ->
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, """
          <D:multistatus xmlns:D="DAV:">
            <D:response>
              <D:href>/</D:href>
              <D:propstat>
                <D:prop>
                  <D:current-user-principal>
                    <D:href>/principals/users/user/</D:href>
                  </D:current-user-principal>
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
              </D:propstat>
            </D:response>
          </D:multistatus>
          """)
        end
      )

      assert {:ok, _message} = Base.test_connection(@caldav_client, ip_address: "127.0.0.1")
    end

    test "discover_calendars follows full RFC 4791 chain when discovery path is not found" do
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        cond do
          n == 1 ->
            # Guessed discovery path → 404
            Conn.send_resp(conn, 404, "")

          n == 2 ->
            # RFC 4791 step 1: current-user-principal at server root
            assert conn.request_path == "/"

            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, """
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:propstat>
                  <D:prop>
                    <D:current-user-principal>
                      <D:href>/principals/users/user/</D:href>
                    </D:current-user-principal>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """)

          n == 3 ->
            # RFC 4791 step 2: calendar-home-set at principal URL
            assert conn.request_path == "/principals/users/user/"

            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, """
            <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
              <D:response>
                <D:propstat>
                  <D:prop>
                    <C:calendar-home-set>
                      <D:href>/calendars/user/</D:href>
                    </C:calendar-home-set>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """)

          n == 4 ->
            # RFC 4791 step 3: list calendars at calendar-home-set
            assert conn.request_path == "/calendars/user/"

            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"/>")
        end
      end)

      assert {:ok, []} = Base.discover_calendars(@caldav_client, skip_breaker: true)
    end

    test "test_connection propagates :unauthorized even when RFC 4791 probe also returns 401" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} =
               Base.test_connection(
                 %{@caldav_client | password: "bad"},
                 ip_address: "127.0.0.1"
               )
    end
  end

  # Regression tests for path doubling when base_url contains a CalDAV principal
  # path (e.g. https://server/dav/user@example.com). CalDAV PROPFIND responses
  # always return server-root-relative hrefs, so calendar_path values like
  # "/dav/user%40example.com/Calendar/" must be appended to the server origin
  # only — not to the full base_url — to avoid doubling the path.
  describe "URL construction with path-containing base_url" do
    # skip_breaker: true keeps execution in the test process so Req.Test stubs work.
    # Without it the circuit breaker dispatches via GenServer, a different process
    # that has no access to the per-process stub registry.

    test "fetch_events sends REPORT to correct path regardless of base_url path depth" do
      # Verifies both: path-containing base_url (Zimbra) and server-root base_url both
      # produce the same server-root-relative REPORT path — no path doubling.
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
          provider: :zimbra
        }

        assert {:ok, []} =
                 Base.fetch_events(
                   client,
                   "/dav/user%40example.com/Calendar/",
                   ~U[2026-01-01 00:00:00Z],
                   ~U[2026-03-01 00:00:00Z],
                   skip_breaker: true
                 )
      end
    end

    test "create_calendar_event sends PUT to server-root path when base_url contains CalDAV path" do
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
        provider: :zimbra
      }

      event_data = %{
        summary: "Test",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert {:ok, _uid} =
               Base.create_calendar_event(
                 client,
                 "/dav/user%40example.com/Calendar/",
                 event_data,
                 skip_breaker: true
               )
    end

    test "non-standard port is preserved when base_url contains a path" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "REPORT"
        assert conn.request_path == "/alice/calendar/"

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"/>")
      end)

      # Radicale on a non-standard port with a path-containing base_url
      client = %{
        base_url: "https://radicale.example.com:8443/principals/alice",
        username: "alice",
        password: "pass",
        calendar_paths: ["/alice/calendar/"],
        provider: :radicale
      }

      assert {:ok, []} =
               Base.fetch_events(
                 client,
                 "/alice/calendar/",
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2026-03-01 00:00:00Z],
                 skip_breaker: true
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Event CRUD scenarios — ETag round-trips and error responses
  # ---------------------------------------------------------------------------

  describe "update_calendar_event/5" do
    test "sends HEAD then PUT with If-Match header from ETag" do
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
               Base.update_calendar_event(
                 @caldav_client_with_paths,
                 "/calendars/user/personal/",
                 "some-uid",
                 event_data,
                 skip_breaker: true
               )
    end

    test "proceeds with PUT when HEAD fails — falls back to If-Match: *" do
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
               Base.update_calendar_event(
                 @caldav_client_with_paths,
                 "/calendars/user/personal/",
                 "new-uid",
                 event_data,
                 skip_breaker: true
               )
    end

    test "returns error on 412 Precondition Failed (concurrent modification)" do
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

      assert {:error, _reason} =
               Base.update_calendar_event(
                 @caldav_client_with_paths,
                 "/calendars/user/personal/",
                 "conflict-uid",
                 event_data,
                 skip_breaker: true
               )
    end
  end

  describe "fetch_events/5" do
    test "accepts 200 OK in addition to 207 Multi-Status" do
      # Some non-standard servers return 200 instead of 207 for REPORT
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "REPORT"

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(200, "<D:multistatus xmlns:D=\"DAV:\"/>")
      end)

      assert {:ok, []} =
               Base.fetch_events(
                 @caldav_client_with_paths,
                 "/calendars/user/personal/",
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2026-03-01 00:00:00Z],
                 skip_breaker: true
               )
    end

    test "parses real events from REPORT response" do
      # iCal data must start at column 0 — iCal parsers treat leading spaces as
      # property folding (RFC 5545 §3.1), so indented heredocs break parsing.
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
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, xml_response)
      end)

      assert {:ok, events} =
               Base.fetch_events(
                 @caldav_client_with_paths,
                 "/calendars/user/personal/",
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2026-03-01 00:00:00Z],
                 skip_breaker: true
               )

      assert length(events) == 1
      [event] = events
      assert event.uid == "test-event-001@example.com"
      assert event.summary == "Integration Test Event"
    end
  end

  describe "delete_event/4 idempotence" do
    test "tolerates 404 (event already deleted)" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        Conn.send_resp(conn, 404, "")
      end)

      # 404 on delete is idempotent — should succeed
      assert {:ok, _response} =
               Base.delete_event(
                 "https://caldav.example.com/calendars/user/personal/gone.ics",
                 "user",
                 "pass"
               )
    end
  end

  # ---------------------------------------------------------------------------
  # RFC 4791 discovery edge cases
  # ---------------------------------------------------------------------------

  describe "RFC 4791 discovery partial failures" do
    test "discover_calendars returns error when current-user-principal href is missing" do
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        if n == 1 do
          # Guessed discovery path → 404
          Conn.send_resp(conn, 404, "")
        else
          # RFC 4791 probe — server returns 207 but omits current-user-principal
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"><D:response/></D:multistatus>")
        end
      end)

      # Should return error since we can't determine the calendar home
      assert {:error, _reason} = Base.discover_calendars(@caldav_client, skip_breaker: true)
    end

    test "test_connection succeeds via RFC 4791 when discovery path returns 5xx" do
      # Route by request path so propfind's :server_error retries all hit the
      # discovery URL (consistently 500), exhaust their retry budget, and trigger
      # the RFC 4791 fallback. Without path-based routing, a counter-based stub
      # would return 207 on the first retry, causing propfind to succeed without
      # ever reaching the fallback.
      ReqTest.stub(:tymeslot_http, fn conn ->
        if conn.request_path == "/" do
          # RFC 4791 probe to server root succeeds
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, """
          <D:multistatus xmlns:D="DAV:">
            <D:response>
              <D:propstat>
                <D:prop>
                  <D:current-user-principal>
                    <D:href>/principals/users/user/</D:href>
                  </D:current-user-principal>
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
              </D:propstat>
            </D:response>
          </D:multistatus>
          """)
        else
          # All guessed discovery paths (e.g. /calendars/user/) return 500.
          # propfind retries :server_error — all retries also return 500 here,
          # exhausting the retry budget and triggering the fallback.
          Conn.send_resp(conn, 500, "Internal Server Error")
        end
      end)

      assert {:ok, _msg} = Base.test_connection(@caldav_client, ip_address: "127.0.0.1")
    end
  end
end
