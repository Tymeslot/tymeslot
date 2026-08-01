defmodule Tymeslot.Integrations.Calendar.CalDAV.XmlHandlerRequestsTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler

  # current-user-principal PROPFIND response (Zimbra-style)
  @principal_response_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:">
    <D:response>
      <D:href>/</D:href>
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
  """

  # calendar-home-set PROPFIND response
  @home_set_response_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/principals/users/user%40example.com/</D:href>
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
  """

  # ---------------------------------------------------------------------------
  # build_propfind_request/1
  # ---------------------------------------------------------------------------

  describe "build_propfind_request/1" do
    test "default request includes displayname and resourcetype" do
      xml = XmlHandler.build_propfind_request()

      assert String.contains?(xml, "displayname")
      assert String.contains?(xml, "resourcetype")
      assert String.contains?(xml, "DAV:")
    end

    test "current_user_principal property is included when requested" do
      xml = XmlHandler.build_propfind_request(properties: [:current_user_principal])
      assert String.contains?(xml, "current-user-principal")
    end

    test "calendar_home_set property uses caldav namespace" do
      xml = XmlHandler.build_propfind_request(properties: [:calendar_home_set])
      assert String.contains?(xml, "calendar-home-set")
      assert String.contains?(xml, "urn:ietf:params:xml:ns:caldav")
    end

    test "default request includes current-user-privilege-set and supported-calendar-component-set" do
      xml = XmlHandler.build_propfind_request()

      assert String.contains?(xml, "current-user-privilege-set")
      assert String.contains?(xml, "supported-calendar-component-set")
    end

    test "produces well-formed XML string" do
      xml = XmlHandler.build_propfind_request()
      assert String.starts_with?(String.trim(xml), "<?xml")
    end

    test "getctag property uses the calendarserver.org namespace, not DAV:" do
      xml = XmlHandler.build_propfind_request(properties: [:getctag])

      assert String.contains?(xml, "getctag")
      assert String.contains?(xml, "http://calendarserver.org/ns/")
      refute String.contains?(xml, "<d:getctag/>")
    end

    test "sync_token property emits the hyphenated DAV:sync-token, not sync_token" do
      xml = XmlHandler.build_propfind_request(properties: [:sync_token])

      assert String.contains?(xml, "sync-token")
      refute String.contains?(xml, "sync_token")
    end

    test "raises on an unknown property atom instead of emitting a guessed element" do
      assert_raise ArgumentError, fn ->
        XmlHandler.build_propfind_request(properties: [:something_unmapped])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # build_calendar_query/2
  # ---------------------------------------------------------------------------

  describe "build_calendar_query/2" do
    test "formats datetimes in CalDAV format (no separators, Z suffix)" do
      start_time = ~U[2026-02-24 09:00:00Z]
      end_time = ~U[2026-02-24 17:00:00Z]

      xml = XmlHandler.build_calendar_query(start_time, end_time)

      assert String.contains?(xml, "20260224T090000Z")
      assert String.contains?(xml, "20260224T170000Z")
    end

    test "includes time-range filter in VEVENT comp-filter" do
      xml = XmlHandler.build_calendar_query(~U[2026-01-01 00:00:00Z], ~U[2026-02-01 00:00:00Z])

      assert String.contains?(xml, "time-range")
      assert String.contains?(xml, "comp-filter")
      assert String.contains?(xml, "VEVENT")
      assert String.contains?(xml, "VCALENDAR")
    end

    test "requests getetag and calendar-data properties" do
      xml = XmlHandler.build_calendar_query(~U[2026-01-01 00:00:00Z], ~U[2026-02-01 00:00:00Z])

      assert String.contains?(xml, "getetag")
      assert String.contains?(xml, "calendar-data")
    end
  end

  # ---------------------------------------------------------------------------
  # parse_current_user_principal/1
  # ---------------------------------------------------------------------------

  describe "parse_current_user_principal/1" do
    test "extracts the principal href" do
      assert {:ok, href} = XmlHandler.parse_current_user_principal(@principal_response_xml)
      assert href == "/principals/users/user%40example.com/"
    end

    test "returns :not_found when element is absent" do
      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:multistatus xmlns:D="DAV:">
        <D:response>
          <D:propstat>
            <D:prop/>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:error, :not_found} = XmlHandler.parse_current_user_principal(xml)
    end

    test "returns error on malformed XML" do
      assert {:error, _reason} = XmlHandler.parse_current_user_principal("<<< garbage")
    end

    test "handles Zimbra namespace prefix D: correctly" do
      # Zimbra uses D: prefix (uppercase)
      assert {:ok, "/principals/users/user%40example.com/"} =
               XmlHandler.parse_current_user_principal(@principal_response_xml)
    end

    test "handles DAV: namespace without prefix (Radicale-style)" do
      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <multistatus xmlns="DAV:">
        <response>
          <propstat>
            <prop>
              <current-user-principal>
                <href>/alice/</href>
              </current-user-principal>
            </prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
      </multistatus>
      """

      assert {:ok, "/alice/"} = XmlHandler.parse_current_user_principal(xml)
    end
  end

  # ---------------------------------------------------------------------------
  # parse_calendar_home_set/1
  # ---------------------------------------------------------------------------

  describe "parse_calendar_home_set/1" do
    test "extracts the calendar-home-set href" do
      assert {:ok, href} = XmlHandler.parse_calendar_home_set(@home_set_response_xml)
      assert href == "/dav/user%40example.com/"
    end

    test "returns :not_found when element is absent" do
      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:multistatus xmlns:D="DAV:">
        <D:response>
          <D:propstat>
            <D:prop/>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:error, :not_found} = XmlHandler.parse_calendar_home_set(xml)
    end

    test "returns error on malformed XML" do
      assert {:error, _reason} = XmlHandler.parse_calendar_home_set("<<< garbage")
    end

    test "handles Nextcloud CalDAV namespace C: prefix" do
      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:propstat>
            <D:prop>
              <C:calendar-home-set>
                <D:href>/remote.php/dav/calendars/alice/</D:href>
              </C:calendar-home-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, "/remote.php/dav/calendars/alice/"} =
               XmlHandler.parse_calendar_home_set(xml)
    end
  end
end
