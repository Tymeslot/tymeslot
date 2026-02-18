defmodule Tymeslot.Integrations.Calendar.Shared.XmlParserTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Shared.XmlParser

  describe "parse_calendar_discovery_response/2" do
    test "parses standard CalDAV discovery response" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:response>
          <d:href>/calendars/user/personal/</d:href>
          <d:propstat>
            <d:prop>
              <d:displayname>Personal</d:displayname>
              <d:resourcetype>
                <d:collection/>
                <c:calendar/>
              </d:resourcetype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/calendars/user/work/</d:href>
          <d:propstat>
            <d:prop>
              <d:displayname>Work</d:displayname>
              <d:resourcetype>
                <d:collection/>
                <c:calendar/>
              </d:resourcetype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
      """

      assert {:ok, calendars} = XmlParser.parse_calendar_discovery_response(xml)
      assert length(calendars) == 2

      personal = Enum.find(calendars, &(&1.name == "Personal"))
      assert personal.path == "/calendars/user/personal/"
      assert personal.type == "calendar"

      work = Enum.find(calendars, &(&1.name == "Work"))
      assert work.path == "/calendars/user/work/"
    end

    test "parses Nextcloud/namespaced responses" do
      xml = """
      <d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
        <d:response>
          <d:href>/remote.php/dav/calendars/admin/personal/</d:href>
          <d:propstat>
            <d:prop>
              <d:displayname>Admin Personal</d:displayname>
              <d:resourcetype>
                <d:collection/>
                <cal:calendar/>
              </d:resourcetype>
            </d:prop>
          </d:propstat>
        </d:response>
      </d:multistatus>
      """

      assert {:ok, [%{name: "Admin Personal", path: path}]} =
               XmlParser.parse_calendar_discovery_response(xml)

      assert path == "/remote.php/dav/calendars/admin/personal/"
    end

    test "falls back to path if displayname is missing" do
      xml = """
      <response>
        <href>/calendars/user/vacation/</href>
        <propstat>
          <prop>
            <resourcetype><c:calendar/></resourcetype>
          </prop>
        </propstat>
      </response>
      """

      assert {:ok, [%{name: "vacation"}]} = XmlParser.parse_calendar_discovery_response(xml)
    end

    test "includes id and selected when requested" do
      xml =
        "<response><href>/cal/</href><prop><displayname>N</displayname><resourcetype><c:calendar/></resourcetype></prop></response>"

      assert {:ok, [cal]} =
               XmlParser.parse_calendar_discovery_response(xml,
                 include_id: true,
                 include_selected: true
               )

      assert cal.id == "/cal/"
      assert cal.selected == false
    end

    test "returns error on invalid XML structure" do
      # While the parser uses regex, we want to ensure it handles non-matching cases
      assert {:error, "Failed to parse calendar discovery response"} =
               XmlParser.parse_calendar_discovery_response(nil)
    end
  end

  describe "extract_calendar_name_from_path/1" do
    test "extracts from Nextcloud format" do
      assert XmlParser.extract_calendar_name_from_path("/remote.php/dav/calendars/user/my-cal/") ==
               "my-cal"
    end

    test "extracts from standard CalDAV format" do
      assert XmlParser.extract_calendar_name_from_path("/calendars/user/work-events/") ==
               "work-events"
    end

    test "extracts last segment as fallback" do
      assert XmlParser.extract_calendar_name_from_path("/some/random/path/to/calendar/") ==
               "calendar"
    end

    test "returns 'calendar' for empty or root path" do
      assert XmlParser.extract_calendar_name_from_path("/") == "calendar"
      assert XmlParser.extract_calendar_name_from_path("") == "calendar"
    end
  end

  describe "build_propfind_request/0" do
    test "returns valid PROPFIND XML" do
      xml = XmlParser.build_propfind_request()
      assert xml =~ "<d:propfind"
      assert xml =~ "<d:displayname"
      assert xml =~ "<c:supported-calendar-component-set"
    end
  end

  describe "parse_calendar_home_set/1" do
    test "extracts home set href" do
      xml = "<cal:calendar-home-set><d:href>/dav/calendars/user/</d:href></cal:calendar-home-set>"
      assert XmlParser.parse_calendar_home_set(xml) == "/dav/calendars/user/"
    end

    test "returns nil if not found" do
      assert is_nil(XmlParser.parse_calendar_home_set("<other></other>"))
    end
  end

  describe "calendar_collection?/1" do
    test "returns true for various calendar indicators" do
      assert XmlParser.calendar_collection?("<cal:calendar")
      assert XmlParser.calendar_collection?("calendar-collection")
    end

    test "returns false if no indicators" do
      refute XmlParser.calendar_collection?("<d:collection/>")
    end
  end
end
