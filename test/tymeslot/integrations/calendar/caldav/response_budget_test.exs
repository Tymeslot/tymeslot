defmodule Tymeslot.Integrations.Calendar.CalDAV.ResponseBudgetTest do
  # Runs the real HTTPClient, so each byte budget is enforced where it is in
  # production: mid-transfer, below every caller.
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.Http
  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryCache

  @propfind_budget 10 * 1024 * 1024
  @report_budget 8 * 1024 * 1024

  @calendar_query_xml """
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
  END:VEVENT
  END:VCALENDAR</C:calendar-data>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    DiscoveryCache.clear_all()
    :ok
  end

  describe "calendar discovery" do
    test "connecting a CalDAV server whose calendar listing outgrows the budget says so" do
      stub_propfind_body(String.duplicate(" ", @propfind_budget + 1))

      assert {:error, %{discovery: message}} = Discovery.maybe_discover_calendars(attrs())

      assert message ==
               "The calendar server at https://caldav.example.com listed more items than " <>
                 "Tymeslot can process at once. If this address points at a single calendar, " <>
                 "enter your account's server address instead, and Tymeslot will find your " <>
                 "calendars there."
    end

    test "a calendar listing exactly at the budget is read" do
      listing = """
      <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:response>
          <D:href>/calendars/user/work/</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>Work</D:displayname>
              <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
      </D:multistatus>
      """

      stub_propfind_body(padded(listing, @propfind_budget))

      assert {:ok, %{calendar_paths: ["/calendars/user/work/"]}} =
               Discovery.maybe_discover_calendars(attrs())
    end
  end

  describe "Http.propfind/4" do
    test "abandons a PROPFIND body past 10 MB as too large, and reads one at 10 MB" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        size = if conn.request_path == "/over/", do: @propfind_budget + 1, else: @propfind_budget
        send(test_pid, :propfind)

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, String.duplicate("x", size))
      end)

      assert {:error, :response_too_large} =
               Http.propfind("https://caldav.example.com/over/", "user", "pass")

      # Not retried: the server answered, and would answer the same again.
      assert_received :propfind
      refute_received :propfind

      assert {:ok, %Req.Response{status: 207}} =
               Http.propfind("https://caldav.example.com/at/", "user", "pass")
    end
  end

  describe "XmlHandler.parse_calendar_query/1" do
    test "refuses a body past the 8 MB REPORT budget like a malformed one, and reads one at it" do
      assert XmlHandler.parse_calendar_query(padded(@calendar_query_xml, @report_budget + 1)) ==
               {:error, "Failed to parse calendar query response"}

      assert {:ok, [%{uid: "meeting-abc@example.com"}]} =
               XmlHandler.parse_calendar_query(padded(@calendar_query_xml, @report_budget))
    end
  end

  # Trailing whitespace after the root element is well-formed, so a valid
  # response can be padded to any size.
  defp padded(xml, size), do: xml <> String.duplicate(" ", size - byte_size(xml))

  defp attrs do
    %{
      provider: "caldav",
      base_url: "https://caldav.example.com",
      username: "user",
      password: "pass",
      user_id: 1
    }
  end

  defp stub_propfind_body(body) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_content_type("application/xml")
      |> Conn.resp(207, body)
    end)
  end
end
