defmodule Tymeslot.Integrations.Calendar.CalDAV.XmlHandlerTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler

  # ---------------------------------------------------------------------------
  # Fixtures — realistic XML responses captured from real CalDAV servers.
  # Each fixture is self-contained so tests read clearly without extra lookups.
  # ---------------------------------------------------------------------------

  # Nextcloud 28 — two calendars, one with color
  @nextcloud_discovery_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"
                 xmlns:cal="urn:ietf:params:xml:ns:caldav"
                 xmlns:cs="http://calendarserver.org/ns/"
                 xmlns:oc="http://owncloud.org/ns"
                 xmlns:nc="http://nextcloud.com/ns"
                 xmlns:apple="http://apple.com/ns/ical/">
    <d:response>
      <d:href>/remote.php/dav/calendars/alice/personal/</d:href>
      <d:propstat>
        <d:prop>
          <d:displayname>Personal</d:displayname>
          <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
          <apple:calendar-color>#1D6EC3FF</apple:calendar-color>
        </d:prop>
        <d:status>HTTP/1.1 200 OK</d:status>
      </d:propstat>
    </d:response>
    <d:response>
      <d:href>/remote.php/dav/calendars/alice/work/</d:href>
      <d:propstat>
        <d:prop>
          <d:displayname>Work</d:displayname>
          <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
        </d:prop>
        <d:status>HTTP/1.1 200 OK</d:status>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """

  # Radicale 3 — calendar collection with .ics suffix paths
  @radicale_discovery_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"
               xmlns:I="http://apple.com/ns/ical/">
    <response>
      <href>/alice/calendar.ics/</href>
      <propstat>
        <prop>
          <displayname>Calendar</displayname>
          <resourcetype><collection/><C:calendar/></resourcetype>
          <I:calendar-color>#FF0000</I:calendar-color>
        </prop>
        <status>HTTP/1.1 200 OK</status>
      </propstat>
    </response>
    <response>
      <href>/alice/</href>
      <propstat>
        <prop>
          <resourcetype><collection/></resourcetype>
        </prop>
        <status>HTTP/1.1 200 OK</status>
      </propstat>
    </response>
  </multistatus>
  """

  # Zimbra — email-based paths, URL-encoded @ character
  @zimbra_discovery_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"
                 xmlns:A="http://apple.com/ns/ical/">
    <D:response>
      <D:href>/dav/user%40example.com/Calendar/</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname>Calendar</D:displayname>
          <D:resourcetype>
            <D:collection/>
            <C:calendar/>
          </D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
    <D:response>
      <D:href>/dav/user%40example.com/</D:href>
      <D:propstat>
        <D:prop>
          <D:resourcetype><D:collection/></D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  # Empty — valid XML multistatus with no calendar responses
  @empty_discovery_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:"/>
  """

  # Discovery with no displayname — name should be inferred from href
  @no_displayname_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/calendars/bob/work_calendar/</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname></D:displayname>
          <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  # Calendar REPORT response — two events with realistic iCal data
  @calendar_query_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/calendars/user/personal/meeting-abc.ics</D:href>
      <D:propstat>
        <D:prop>
          <D:getetag>"etag-abc-123"</D:getetag>
          <C:calendar-data>BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//Test//EN
  BEGIN:VEVENT
  UID:meeting-abc@example.com
  DTSTART:20300601T100000Z
  DTEND:20300601T110000Z
  SUMMARY:Team Meeting
  DESCRIPTION:Weekly sync
  END:VEVENT
  END:VCALENDAR</C:calendar-data>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
    <D:response>
      <D:href>/calendars/user/personal/lunch-xyz.ics</D:href>
      <D:propstat>
        <D:prop>
          <D:getetag>"etag-xyz-456"</D:getetag>
          <C:calendar-data>BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//Test//EN
  BEGIN:VEVENT
  UID:lunch-xyz@example.com
  DTSTART:20300601T120000Z
  DTEND:20300601T130000Z
  SUMMARY:Lunch
  END:VEVENT
  END:VCALENDAR</C:calendar-data>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  # Calendar REPORT response with no events
  @empty_calendar_query_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"/>
  """

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
  # parse_calendar_discovery/2
  # ---------------------------------------------------------------------------

  describe "parse_calendar_discovery/2" do
    test "parses Nextcloud response — returns only calendar collections" do
      assert {:ok, calendars} = XmlHandler.parse_calendar_discovery(@nextcloud_discovery_xml)

      assert length(calendars) == 2

      assert Enum.any?(calendars, fn cal ->
               cal.href == "/remote.php/dav/calendars/alice/personal/" and
                 cal.name == "Personal" and
                 cal.color == "#1D6EC3FF"
             end)

      assert Enum.any?(calendars, fn cal ->
               cal.href == "/remote.php/dav/calendars/alice/work/" and
                 cal.name == "Work"
             end)
    end

    test "parses Radicale response — filters out non-calendar collection" do
      assert {:ok, calendars} = XmlHandler.parse_calendar_discovery(@radicale_discovery_xml)

      # Only the calendar collection, not the bare /alice/ collection
      assert length(calendars) == 1
      [cal] = calendars
      assert cal.href == "/alice/calendar.ics/"
      assert cal.name == "Calendar"
    end

    test "parses Zimbra response with URL-encoded email paths" do
      assert {:ok, calendars} = XmlHandler.parse_calendar_discovery(@zimbra_discovery_xml)

      assert length(calendars) == 1
      [cal] = calendars
      assert cal.href == "/dav/user%40example.com/Calendar/"
      assert cal.name == "Calendar"
    end

    test "returns empty list when no calendars in response" do
      assert {:ok, []} = XmlHandler.parse_calendar_discovery(@empty_discovery_xml)
    end

    test "infers calendar name from href when displayname is absent" do
      assert {:ok, [cal]} = XmlHandler.parse_calendar_discovery(@no_displayname_xml)

      # Name is derived from the last path segment, underscores replaced with spaces
      assert cal.name == "Work calendar"
    end

    test "each calendar has required keys" do
      assert {:ok, [cal | _rest]} = XmlHandler.parse_calendar_discovery(@nextcloud_discovery_xml)

      assert Map.has_key?(cal, :id)
      assert Map.has_key?(cal, :href)
      assert Map.has_key?(cal, :name)
      assert Map.has_key?(cal, :color)
      assert Map.has_key?(cal, :selected)
    end

    test "selected defaults to false" do
      assert {:ok, [cal | _rest]} = XmlHandler.parse_calendar_discovery(@nextcloud_discovery_xml)
      refute cal.selected
    end

    test "returns error on malformed XML" do
      assert {:error, _reason} = XmlHandler.parse_calendar_discovery("<not xml at all <<<")
    end

    test "accepts calendar that omits supported-calendar-component-set (RFC 4791 implies VEVENT)" do
      # Legacy / minimalist servers (some Radicale and Baikal versions) don't
      # advertise components. The shared filter must default-accept them, not
      # silently drop the only calendar.
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/calendars/user/personal/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Personal</D:displayname>
              <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, [cal]} = XmlHandler.parse_calendar_discovery(xml)
      assert cal.name == "Personal"
      assert cal.read_only == false
    end

    test "filters out a VTODO-only collection while keeping VEVENT siblings" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/calendars/user/events/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Events</D:displayname>
              <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
              <C:supported-calendar-component-set>
                <C:comp name="VEVENT"/>
              </C:supported-calendar-component-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        <D:response>
          <D:href>/calendars/user/tasks/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Tasks</D:displayname>
              <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
              <C:supported-calendar-component-set>
                <C:comp name="VTODO"/>
              </C:supported-calendar-component-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, [cal]} = XmlHandler.parse_calendar_discovery(xml)
      assert cal.name == "Events"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_calendar_query/1
  # ---------------------------------------------------------------------------

  describe "parse_calendar_query/1" do
    test "parses two events from a calendar-query response" do
      assert {:ok, events} = XmlHandler.parse_calendar_query(@calendar_query_xml)

      assert length(events) == 2

      assert Enum.any?(events, fn e ->
               e.uid == "meeting-abc@example.com" and
                 e.summary == "Team Meeting"
             end)

      assert Enum.any?(events, fn e ->
               e.uid == "lunch-xyz@example.com" and
                 e.summary == "Lunch"
             end)
    end

    test "each event carries the href and etag from the response" do
      assert {:ok, events} = XmlHandler.parse_calendar_query(@calendar_query_xml)

      meeting = Enum.find(events, &(&1.uid == "meeting-abc@example.com"))
      assert meeting.href == "/calendars/user/personal/meeting-abc.ics"
      # ETag quotes are stripped by clean_etag/1
      assert meeting.etag == "etag-abc-123"
    end

    test "returns empty list when calendar has no events" do
      assert {:ok, []} = XmlHandler.parse_calendar_query(@empty_calendar_query_xml)
    end

    test "skips entries with invalid iCal data rather than crashing" do
      xml_with_bad_ical = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/calendars/user/personal/bad.ics</D:href>
          <D:propstat>
            <D:prop>
              <D:getetag>"etag"</D:getetag>
              <C:calendar-data>NOT VALID ICAL DATA</C:calendar-data>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        <D:response>
          <D:href>/calendars/user/personal/good.ics</D:href>
          <D:propstat>
            <D:prop>
              <D:getetag>"etag-good"</D:getetag>
              <C:calendar-data>BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:good@example.com
      DTSTART:20300601T100000Z
      DTEND:20300601T110000Z
      SUMMARY:Good Event
      END:VEVENT
      END:VCALENDAR</C:calendar-data>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      assert {:ok, events} = XmlHandler.parse_calendar_query(xml_with_bad_ical)

      # Bad iCal entry is silently dropped; good one is returned
      assert length(events) == 1
      assert hd(events).uid == "good@example.com"
    end

    test "returns error on malformed XML" do
      assert {:error, _reason} = XmlHandler.parse_calendar_query("<<< not xml")
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

    test "produces well-formed XML string" do
      xml = XmlHandler.build_propfind_request()
      assert String.starts_with?(String.trim(xml), "<?xml")
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
end
