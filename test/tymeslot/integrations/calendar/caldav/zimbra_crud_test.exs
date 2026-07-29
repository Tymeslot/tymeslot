defmodule Tymeslot.Integrations.Calendar.CalDAV.ZimbraCrudTest do
  use Tymeslot.CalDAVCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.{Discovery, Events}

  # ---------------------------------------------------------------------------
  # Zimbra-specific CRUD tests
  # Verifies that update and delete build the correct server-root-relative URL
  # when base_url contains a Zimbra DAV principal path. The calendar_path hrefs
  # returned by Zimbra are server-root-relative (e.g. /dav/user%40example.com/Calendar/),
  # so they must be appended to the origin only — not to the full base_url —
  # to avoid path doubling.
  # ---------------------------------------------------------------------------

  describe "update_calendar_event/5 with Zimbra path-containing base_url" do
    test "sends HEAD and PUT to server-root path, not doubled path" do
      stub_sequential(
        fn conn ->
          assert conn.method == "HEAD"
          assert conn.request_path == "/dav/user%40example.com/Calendar/some-uid.ics"
          refute String.contains?(conn.request_path, "/dav/user@example.com/dav/")

          conn
          |> Conn.put_resp_header("etag", "\"124606-124606\"")
          |> Conn.send_resp(200, "")
        end,
        fn conn ->
          assert conn.method == "PUT"
          assert conn.request_path == "/dav/user%40example.com/Calendar/some-uid.ics"
          refute String.contains?(conn.request_path, "/dav/user@example.com/dav/")

          [if_match | _rest] = Conn.get_req_header(conn, "if-match")
          assert if_match == "\"124606-124606\""

          Conn.send_resp(conn, 204, "")
        end
      )

      client = %{
        base_url: "https://caldav.example.com/dav/user@example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user%40example.com/Calendar/"],
        verify_ssl: true,
        provider: :zimbra
      }

      event_data = %{
        summary: "Updated",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert :ok =
               Events.update_calendar_event(
                 client,
                 "/dav/user%40example.com/Calendar/",
                 "some-uid",
                 event_data,
                 skip_breaker: true
               )
    end

    test "uses Zimbra-style numeric ETag format correctly" do
      # Zimbra ETags look like "124606-124606" — verify they are passed through
      # the If-Match header without modification.
      stub_sequential(
        fn conn ->
          conn
          |> Conn.put_resp_header("etag", "\"999123-999123\"")
          |> Conn.send_resp(200, "")
        end,
        fn conn ->
          [if_match | _rest] = Conn.get_req_header(conn, "if-match")
          assert if_match == "\"999123-999123\""
          Conn.send_resp(conn, 204, "")
        end
      )

      client = %{
        base_url: "https://zm.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user%40example.com/Calendar/"],
        verify_ssl: true,
        provider: :zimbra
      }

      assert :ok =
               Events.update_calendar_event(
                 client,
                 "/dav/user%40example.com/Calendar/",
                 "some-uid",
                 %{
                   summary: "Updated",
                   start_time: ~U[2026-02-24 10:00:00Z],
                   end_time: ~U[2026-02-24 11:00:00Z]
                 },
                 skip_breaker: true
               )
    end
  end

  describe "delete_calendar_event/4 with Zimbra path-containing base_url" do
    test "sends DELETE to server-root path, not doubled path" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/dav/user%40example.com/Calendar/some-uid.ics"
        refute String.contains?(conn.request_path, "/dav/user@example.com/dav/")

        Conn.send_resp(conn, 204, "")
      end)

      client = %{
        base_url: "https://caldav.example.com/dav/user@example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user%40example.com/Calendar/"],
        verify_ssl: true,
        provider: :zimbra
      }

      assert :ok =
               Events.delete_calendar_event(
                 client,
                 "/dav/user%40example.com/Calendar/",
                 "some-uid",
                 skip_breaker: true
               )
    end

    test "tolerates 404 when Zimbra event is already gone" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        Conn.send_resp(conn, 404, "")
      end)

      client = %{
        base_url: "https://zm.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user%40example.com/Calendar/"],
        verify_ssl: true,
        provider: :zimbra
      }

      assert :ok =
               Events.delete_calendar_event(
                 client,
                 "/dav/user%40example.com/Calendar/",
                 "gone-uid",
                 skip_breaker: true
               )
    end
  end

  describe "RFC 4791 discovery with provider: :zimbra" do
    # Zimbra's guessed discovery path is /dav/{username}/ which exists but
    # returns USER_ROOT (not the calendar home). When that path returns 404 or
    # 500, the RFC 4791 chain (/ → current-user-principal → calendar-home-set)
    # must kick in and locate the correct /dav/user%40example.com/ home.
    test "discover_calendars follows RFC 4791 chain when Zimbra guessed path fails" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        cond do
          conn.request_path == "/" ->
            # RFC 4791 step 1: current-user-principal at server root
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, """
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:propstat>
                  <D:prop>
                    <D:current-user-principal>
                      <D:href>/principals/users/user%40example.com/</D:href>
                    </D:current-user-principal>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """)

          conn.request_path == "/principals/users/user%40example.com/" ->
            # RFC 4791 step 2: calendar-home-set at principal URL
            # Zimbra returns the percent-encoded email path as the home set.
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, """
            <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
              <D:response>
                <D:propstat>
                  <D:prop>
                    <C:calendar-home-set>
                      <D:href>/dav/user%40example.com/</D:href>
                    </C:calendar-home-set>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """)

          conn.request_path == "/dav/user%40example.com/" ->
            # RFC 4791 step 3: list calendars at home set — one calendar returned
            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, """
            <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
              <D:response>
                <D:href>/dav/user%40example.com/Calendar/</D:href>
                <D:propstat>
                  <D:prop>
                    <D:displayname>Calendar</D:displayname>
                    <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """)

          true ->
            # Zimbra guessed discovery path /dav/user/ → 404
            Conn.send_resp(conn, 404, "")
        end
      end)

      client = %{
        base_url: "https://zm.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        verify_ssl: true,
        provider: :zimbra
      }

      assert {:ok, [calendar]} = Discovery.discover_calendars(client, skip_breaker: true)
      assert calendar.path == "/dav/user%40example.com/Calendar/"
      assert calendar.name == "Calendar"
    end
  end
end
