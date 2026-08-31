defmodule Tymeslot.Integrations.Calendar.CalDAV.MailboxOrgCrudTest do
  use Tymeslot.HttpTransportCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.{
    Discovery,
    Events,
    SyncCollectionReport,
    XmlHandler
  }

  # ---------------------------------------------------------------------------
  # mailbox.org / Open-Xchange CRUD wire-format tests
  #
  # Response payloads in this file are taken verbatim from a live probe
  # against https://dav.mailbox.org/ in April 2026. They lock the wire
  # contract so future shared-layer changes cannot silently break this
  # provider.
  # ---------------------------------------------------------------------------

  @calendar_path "/caldav/Y2FsOi8vMC8zMg/"

  defp client(extra \\ %{}) do
    Map.merge(
      %{
        base_url: "https://dav.mailbox.org",
        username: "you@mailbox.org",
        password: "pass",
        calendar_paths: [@calendar_path],
        verify_ssl: true,
        provider: :mailbox_org
      },
      extra
    )
  end

  describe "discovery (mailbox.org enumeration)" do
    test "filters out VTODO-only and schedule-inbox/outbox collections" do
      enumeration_xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:CAL="urn:ietf:params:xml:ns:caldav" xmlns:CS="http://calendarserver.org/ns/">
        <D:response>
          <D:href>/caldav/Y2FsOi8vMC8zMg/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Kalender</D:displayname>
              <D:resourcetype>
                <D:collection/>
                <CAL:calendar/>
              </D:resourcetype>
              <CAL:supported-calendar-component-set>
                <CAL:comp name="VEVENT"/>
              </CAL:supported-calendar-component-set>
              <D:current-user-privilege-set>
                <D:privilege><D:read/></D:privilege>
                <D:privilege><D:write/></D:privilege>
              </D:current-user-privilege-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        <D:response>
          <D:href>/caldav/Y2FsOi8vMS8w/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Geburtstage</D:displayname>
              <D:resourcetype>
                <D:collection/>
                <CAL:calendar/>
              </D:resourcetype>
              <CAL:supported-calendar-component-set>
                <CAL:comp name="VEVENT"/>
              </CAL:supported-calendar-component-set>
              <D:current-user-privilege-set>
                <D:privilege><D:read/></D:privilege>
              </D:current-user-privilege-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        <D:response>
          <D:href>/caldav/MzU/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Aufgaben</D:displayname>
              <D:resourcetype>
                <D:collection/>
                <CAL:calendar/>
              </D:resourcetype>
              <CAL:supported-calendar-component-set>
                <CAL:comp name="VTODO"/>
              </CAL:supported-calendar-component-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        <D:response>
          <D:href>/caldav/schedule-inbox/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Schedule Inbox</D:displayname>
              <D:resourcetype>
                <D:collection/>
                <CAL:schedule-inbox/>
              </D:resourcetype>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        <D:response>
          <D:href>/caldav/schedule-outbox/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Schedule Outbox</D:displayname>
              <D:resourcetype>
                <D:collection/>
                <CAL:schedule-outbox/>
              </D:resourcetype>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, calendars} = XmlHandler.parse_calendar_discovery(enumeration_xml)

      hrefs = Enum.map(calendars, & &1.path)
      names = Enum.map(calendars, & &1.name)

      assert "/caldav/Y2FsOi8vMC8zMg/" in hrefs, "writable VEVENT calendar must be included"
      assert "/caldav/Y2FsOi8vMS8w/" in hrefs, "read-only VEVENT calendar must be included"

      refute "/caldav/MzU/" in hrefs, "VTODO-only calendar must not be enumerated as a calendar"

      refute Enum.any?(hrefs, &String.contains?(&1, "schedule-inbox")),
             "schedule-inbox must be filtered out"

      refute Enum.any?(hrefs, &String.contains?(&1, "schedule-outbox")),
             "schedule-outbox must be filtered out"

      assert "Kalender" in names
      assert "Geburtstage" in names
    end

    test "marks calendars with no write privilege as read_only" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:CAL="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/caldav/Y2FsOi8vMS8w/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Geburtstage</D:displayname>
              <D:resourcetype>
                <D:collection/>
                <CAL:calendar/>
              </D:resourcetype>
              <CAL:supported-calendar-component-set>
                <CAL:comp name="VEVENT"/>
              </CAL:supported-calendar-component-set>
              <D:current-user-privilege-set>
                <D:privilege><D:read/></D:privilege>
              </D:current-user-privilege-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, [calendar]} = XmlHandler.parse_calendar_discovery(xml)
      assert calendar.read_only == true
    end

    test "treats writable calendars as not read-only" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:CAL="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/caldav/Y2FsOi8vMC8zMg/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Kalender</D:displayname>
              <D:resourcetype>
                <D:collection/>
                <CAL:calendar/>
              </D:resourcetype>
              <CAL:supported-calendar-component-set>
                <CAL:comp name="VEVENT"/>
              </CAL:supported-calendar-component-set>
              <D:current-user-privilege-set>
                <D:privilege><D:write/></D:privilege>
              </D:current-user-privilege-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, [calendar]} = XmlHandler.parse_calendar_discovery(xml)
      assert calendar.read_only == false
    end

    test "discovery skips the broken /calendars/<user>/ guess for :mailbox_org" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        if conn.request_path == "/caldav/" do
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, """
          <D:multistatus xmlns:D="DAV:" xmlns:CAL="urn:ietf:params:xml:ns:caldav">
            <D:response>
              <D:href>/caldav/Y2FsOi8vMC8zMg/</D:href>
              <D:propstat>
                <D:prop>
                  <D:displayname>Kalender</D:displayname>
                  <D:resourcetype>
                    <D:collection/>
                    <CAL:calendar/>
                  </D:resourcetype>
                  <CAL:supported-calendar-component-set>
                    <CAL:comp name="VEVENT"/>
                  </CAL:supported-calendar-component-set>
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
              </D:propstat>
            </D:response>
          </D:multistatus>
          """)
        else
          flunk("Discovery should hit /caldav/ directly, got #{conn.request_path}")
        end
      end)

      assert {:ok, [calendar]} = Discovery.discover_calendars(client(), skip_breaker: true)
      assert calendar.path == "/caldav/Y2FsOi8vMC8zMg/"
    end
  end

  describe "sync-collection (mailbox.org tombstone shape)" do
    test "parses tombstones returned as <D:response> with no <D:propstat>" do
      # Open-Xchange's deleted-resource shape: a bare <D:status> sibling of
      # <D:href>, no propstat wrapper. Captured verbatim from the live probe.
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:">
        <D:response>
          <D:href>/caldav/Y2FsOi8vMC8zMg/9d983fc6-11a8-4d3c-b258-2ec3de2d34d8.ics</D:href>
          <D:status>HTTP/1.1 404 NOT FOUND</D:status>
        </D:response>
        <D:sync-token>1777300842214.0.0</D:sync-token>
      </D:multistatus>
      """

      assert {:ok, {events, deleted_hrefs, sync_token}} =
               SyncCollectionReport.parse_response(xml)

      assert events == []

      assert deleted_hrefs == [
               "/caldav/Y2FsOi8vMC8zMg/9d983fc6-11a8-4d3c-b258-2ec3de2d34d8.ics"
             ]

      assert sync_token == "1777300842214.0.0"
    end

    test "preserves Open-Xchange's dotted sync-token verbatim" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:">
        <D:sync-token>1777300729362.0.1</D:sync-token>
      </D:multistatus>
      """

      assert {:ok, {[], [], "1777300729362.0.1"}} = SyncCollectionReport.parse_response(xml)
    end

    test "strips quotes when reading getetag in REPORT responses" do
      # Open-Xchange returns the etag value WITHOUT surrounding quotes inside
      # <D:getetag>, which is the opposite of what it sends in HTTP headers.
      # The parser must normalise both forms.
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/caldav/Y2FsOi8vMC8zMg/abc.ics</D:href>
          <D:propstat>
            <D:prop>
              <D:getetag>2785358-1-1777300729362</D:getetag>
              <C:calendar-data>BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Open-Xchange//8.47.75//EN
      BEGIN:VEVENT
      UID:abc
      DTSTAMP:20260427T143849Z
      DTSTART:20260501T100000Z
      DTEND:20260501T103000Z
      SUMMARY:Probe
      END:VEVENT
      END:VCALENDAR</C:calendar-data>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        <D:sync-token>1777300729362.0.1</D:sync-token>
      </D:multistatus>
      """

      assert {:ok, {events, [], _token}} = SyncCollectionReport.parse_response(xml)
      assert [event] = events
      assert event.etag == "2785358-1-1777300729362"
      assert event.href == "/caldav/Y2FsOi8vMC8zMg/abc.ics"
    end
  end

  describe "PUT semantics (Open-Xchange returns 201 for both create and update)" do
    test "treats 201 on update as success rather than error" do
      stub_sequential(
        fn conn ->
          assert conn.method == "HEAD"

          conn
          |> Conn.put_resp_header("etag", "\"2785358-1-1777300818156\"")
          |> Conn.send_resp(200, "")
        end,
        fn conn ->
          assert conn.method == "PUT"
          [if_match | _rest] = Conn.get_req_header(conn, "if-match")
          assert if_match == "\"2785358-1-1777300818156\""
          # Open-Xchange returns 201 — not 204 — even for updates.
          Conn.send_resp(conn, 201, "")
        end
      )

      assert :ok =
               Events.update_calendar_event(
                 client(),
                 @calendar_path,
                 "9d983fc6-11a8-4d3c-b258-2ec3de2d34d8",
                 %{
                   summary: "Updated",
                   start_time: ~U[2026-05-01 10:00:00Z],
                   end_time: ~U[2026-05-01 11:00:00Z]
                 },
                 skip_breaker: true
               )
    end

    test "create against the base64-id calendar path uses the server-root URL" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/caldav/Y2FsOi8vMC8zMg/new-uid.ics"
        refute String.contains?(conn.request_path, "/caldav/Y2FsOi8vMC8zMg/caldav/")
        Conn.send_resp(conn, 201, "")
      end)

      assert {:ok, "new-uid"} =
               Events.create_calendar_event(
                 client(),
                 @calendar_path,
                 %{
                   uid: "new-uid",
                   summary: "Probe",
                   start_time: ~U[2026-05-01 10:00:00Z],
                   end_time: ~U[2026-05-01 10:30:00Z]
                 },
                 skip_breaker: true
               )
    end
  end

  describe "DELETE with mailbox.org base64 path" do
    test "tolerates 204 success" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/caldav/Y2FsOi8vMC8zMg/some-uid.ics"
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               Events.delete_calendar_event(
                 client(),
                 @calendar_path,
                 "some-uid",
                 skip_breaker: true
               )
    end

    test "treats a stale-If-Match 412 as a precondition failure (no reauth)" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        Conn.send_resp(conn, 412, "")
      end)

      result =
        Events.delete_calendar_event(
          client(),
          @calendar_path,
          "some-uid",
          skip_breaker: true
        )

      assert match?({:error, _}, result)
    end
  end
end
