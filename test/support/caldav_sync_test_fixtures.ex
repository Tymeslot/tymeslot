defmodule Tymeslot.CalDAVSyncTestFixtures do
  @moduledoc """
  Shared fixtures and stub responders for the CalDAV calendar sync worker
  test files under `test/tymeslot/workers/sync_caldav_calendar_worker/`.

  Provides:
    * canned calendar paths and iCal payloads for two example calendars
    * builders for CalDAV multi-status XML responses (REPORT, sync-collection,
      PROPFIND/ctag)
    * a dual-path stub responder used by tier and force-fetch tests
  """

  alias Plug.Conn

  @path1 "/calendars/user/work/"
  @path2 "/calendars/user/personal/"

  @ical_path1 """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//Test//EN
  BEGIN:VEVENT
  UID:event-from-path1@test
  DTSTART:20991215T100000Z
  DTEND:20991215T110000Z
  SUMMARY:Path1 Meeting
  END:VEVENT
  END:VCALENDAR
  """

  @ical_path2 """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//Test//EN
  BEGIN:VEVENT
  UID:event-from-path2@test
  DTSTART:20991215T140000Z
  DTEND:20991215T150000Z
  SUMMARY:Path2 Meeting
  END:VEVENT
  END:VCALENDAR
  """

  @spec path1() :: String.t()
  def path1, do: @path1

  @spec path2() :: String.t()
  def path2, do: @path2

  @spec ical_path1() :: String.t()
  def ical_path1, do: @ical_path1

  @spec ical_path2() :: String.t()
  def ical_path2, do: @ical_path2

  @spec caldav_report_xml(String.t(), String.t()) :: String.t()
  def caldav_report_xml(href, ical_data) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>#{href}</D:href>
        <D:propstat>
          <D:prop>
            <D:getetag>"test-etag"</D:getetag>
            <C:calendar-data>#{String.trim(ical_data)}</C:calendar-data>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end

  @spec sync_collection_xml(String.t(), String.t(), String.t()) :: String.t()
  def sync_collection_xml(href, ical_data, sync_token) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>#{href}</D:href>
        <D:propstat>
          <D:prop>
            <D:getetag>"test-etag"</D:getetag>
            <C:calendar-data>#{String.trim(ical_data)}</C:calendar-data>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:sync-token>#{sync_token}</D:sync-token>
    </D:multistatus>
    """
  end

  @spec ctag_xml(String.t()) :: String.t()
  def ctag_xml(ctag) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">
      <D:response>
        <D:propstat>
          <D:prop>
            <CS:getctag>#{ctag}</CS:getctag>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end

  @doc """
  Stub responder for tests that configure two calendar paths and expect the
  worker to issue a REPORT against each. Returns a canned 207 Multi-Status
  payload for each known path and 404 for anything else.
  """
  @spec respond_to_dual_paths(Plug.Conn.t()) :: Plug.Conn.t()
  def respond_to_dual_paths(conn) do
    case conn.request_path do
      @path1 ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{@path1}event1.ics", @ical_path1))

      @path2 ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{@path2}event2.ics", @ical_path2))

      other ->
        Conn.send_resp(conn, 404, "unexpected path: #{other}")
    end
  end
end
