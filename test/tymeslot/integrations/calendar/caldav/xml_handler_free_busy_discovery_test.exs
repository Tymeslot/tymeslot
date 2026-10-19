defmodule Tymeslot.Integrations.Calendar.CalDAV.XmlHandlerFreeBusyDiscoveryTest do
  @moduledoc """
  Discovery of a calendar shared with the account as busy times only
  (`CALDAV:read-free-busy` without `DAV:read`): kept, marked
  `free_busy_only` so it is read through the free-busy-query REPORT, and
  never inferred from a privilege set the server did not actually report.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler

  describe "parse_calendar_discovery/2" do
    # A free/busy-only share answers a calendar-query REPORT with 403, so it
    # is kept marked for the free-busy-query REPORT instead, read-only.
    test "keeps a calendar whose privilege set grants free/busy but not read, marked so" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/calendars/user/personal/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Personal</D:displayname>
              <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
              <D:current-user-privilege-set>
                <D:privilege><D:all/></D:privilege>
              </D:current-user-privilege-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        <D:response>
          <D:href>/calendars/colleague/availability/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Colleague</D:displayname>
              <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
              <D:current-user-privilege-set>
                <D:privilege><C:read-free-busy/></D:privilege>
              </D:current-user-privilege-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, [personal, colleague]} = XmlHandler.parse_calendar_discovery(xml)

      assert {personal.path, personal.read_only, personal.free_busy_only} ==
               {"/calendars/user/personal/", false, false}

      assert {colleague.path, colleague.read_only, colleague.free_busy_only} ==
               {"/calendars/colleague/availability/", true, true}
    end

    test "leaves out a calendar whose privilege set grants nothing it could be read with" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/calendars/colleague/private/</D:href>
          <D:propstat>
            <D:prop>
              <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
              <D:current-user-privilege-set>
                <D:privilege><D:read-acl/></D:privilege>
              </D:current-user-privilege-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, []} = XmlHandler.parse_calendar_discovery(xml)
    end

    test "never marks a calendar free/busy only on a server reporting no privileges" do
      # The property name echoed back in a 404 propstat, as a server without
      # RFC 3744 support does: no `<privilege>` child, so nothing is known.
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/calendars/user/personal/</D:href>
          <D:propstat>
            <D:prop><D:resourcetype><D:collection/><C:calendar/></D:resourcetype></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
          <D:propstat>
            <D:prop><D:current-user-privilege-set/></D:prop>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, [%{free_busy_only: false, read_only: false}]} =
               XmlHandler.parse_calendar_discovery(xml)
    end
  end
end
