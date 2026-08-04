defmodule Tymeslot.Integrations.Calendar.CalDAV.SyncCollectionReportTest do
  @moduledoc """
  Tests for `Tymeslot.Integrations.Calendar.CalDAV.SyncCollectionReport`.

  The network round-trip is already covered by `CalDAV.Http` tests; this
  module focuses on the pure building/parsing logic:

    * `build_report/1` produces an initial-sync body for `nil` and a
      delta body that embeds (and properly escapes) the stored token.
    * `parse_response/1` splits 207 Multi-Status responses into changed
      events and the hrefs the server reported as removed, surfaces the new
      sync token, and refuses a delta whose event data the server withheld
      rather than mistaking it for a batch of deletions.
    * `parse_ctag_response/1` extracts the CTag or returns `nil` when
      the server omits it.
    * `xml_escape/1` escapes the five characters that would otherwise
      break the wrapping XML body.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalDAV.SyncCollectionReport

  describe "build_report/1" do
    test "nil token produces an initial-sync body with an empty sync-token element" do
      body = SyncCollectionReport.build_report(nil)

      assert body =~ "<d:sync-collection"
      assert body =~ "<d:sync-token/>"
      assert body =~ "<d:sync-level>1</d:sync-level>"
    end

    test "binary token embeds the token value" do
      body = SyncCollectionReport.build_report("https://example.com/sync/token-42")

      assert body =~ "<d:sync-token>https://example.com/sync/token-42</d:sync-token>"
    end

    test "a token containing XML special characters is escaped" do
      body = SyncCollectionReport.build_report(~s(a&b<c>"d'))

      assert body =~ "<d:sync-token>a&amp;b&lt;c&gt;&quot;d&apos;</d:sync-token>"
      refute body =~ "a&b<c>"
    end
  end

  describe "parse_response/1" do
    test "separates changed events from deleted hrefs and extracts the new sync token" do
      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:event-1@example.com
      SUMMARY:Team Sync
      DTSTART:20260401T100000Z
      DTEND:20260401T110000Z
      END:VEVENT
      END:VCALENDAR
      """

      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:response>
          <d:href>/calendars/alice/cal/event-1.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>"etag-1"</d:getetag>
              <c:calendar-data>#{ical}</c:calendar-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/calendars/alice/cal/deleted.ics</d:href>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:response>
        <d:sync-token>https://example.com/sync/new-token</d:sync-token>
      </d:multistatus>
      """

      assert {:ok, {events, deleted, sync_token}} = SyncCollectionReport.parse_response(body)

      assert [event] = events
      assert event.href == "/calendars/alice/cal/event-1.ics"
      assert event.etag == "etag-1"
      assert event.summary == "Team Sync"

      assert deleted == ["/calendars/alice/cal/deleted.ics"]
      assert sync_token == "https://example.com/sync/new-token"
    end

    test "returns nil sync token when the server omits it" do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:">
      </d:multistatus>
      """

      assert {:ok, {[], [], nil}} = SyncCollectionReport.parse_response(body)
    end

    test "returns {:error, :invalid_response} for malformed XML" do
      assert {:error, :invalid_response} = SyncCollectionReport.parse_response("not xml at all")
    end

    test "a changed resource returned without its calendar data is never read as deleted" do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:response>
          <d:href>/calendars/alice/cal/event-1.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>"etag-1"</d:getetag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:sync-token>https://example.com/sync/new-token</d:sync-token>
      </d:multistatus>
      """

      assert capture_log(fn ->
               assert {:error, :calendar_data_withheld} =
                        SyncCollectionReport.parse_response(body)
             end) =~ "withheld event data"
    end

    test "calendar data reported in its own 404 propstat is not a deletion" do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:response>
          <d:href>/calendars/alice/cal/event-1.ics</d:href>
          <d:propstat>
            <d:prop><c:calendar-data/></d:prop>
            <d:status>HTTP/1.1 404 Not Found</d:status>
          </d:propstat>
          <d:propstat>
            <d:prop><d:getetag>"etag-1"</d:getetag></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:sync-token>https://example.com/sync/new-token</d:sync-token>
      </d:multistatus>
      """

      capture_log(fn ->
        assert {:error, :calendar_data_withheld} = SyncCollectionReport.parse_response(body)
      end)
    end

    test "a resource the server removed with a 410 is treated as deleted" do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:">
        <d:response>
          <d:href>/calendars/alice/cal/gone.ics</d:href>
          <d:status>HTTP/1.1 410 Gone</d:status>
        </d:response>
        <d:sync-token>token-9</d:sync-token>
      </d:multistatus>
      """

      assert {:ok, {[], ["/calendars/alice/cal/gone.ics"], "token-9"}} =
               SyncCollectionReport.parse_response(body)
    end

    test "an unparsable event is dropped without failing the whole delta" do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:response>
          <d:href>/calendars/alice/cal/broken.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>"etag-broken"</d:getetag>
              <c:calendar-data>not an icalendar document</c:calendar-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:sync-token>token-10</d:sync-token>
      </d:multistatus>
      """

      assert {:ok, {[], [], "token-10"}} = SyncCollectionReport.parse_response(body)
    end
  end

  describe "parse_ctag_response/1" do
    test "extracts a getctag value when the server includes one" do
      body = """
      <?xml version="1.0"?>
      <d:multistatus xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">
        <d:response>
          <d:href>/calendars/alice/cal/</d:href>
          <d:propstat>
            <d:prop>
              <cs:getctag>"ctag-7"</cs:getctag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
      """

      assert {:ok, "\"ctag-7\""} = SyncCollectionReport.parse_ctag_response(body)
    end

    test "returns nil when the server omits the getctag property" do
      body = """
      <?xml version="1.0"?>
      <d:multistatus xmlns:d="DAV:">
      </d:multistatus>
      """

      assert {:ok, nil} = SyncCollectionReport.parse_ctag_response(body)
    end

    test "returns {:ok, nil} for malformed XML" do
      assert {:ok, nil} = SyncCollectionReport.parse_ctag_response("not xml at all")
    end
  end

  describe "xml_escape/1" do
    test "escapes the five XML special characters" do
      assert SyncCollectionReport.xml_escape(~s(&<>"')) == "&amp;&lt;&gt;&quot;&apos;"
    end

    test "leaves ordinary text unchanged" do
      assert SyncCollectionReport.xml_escape("hello world") == "hello world"
    end
  end
end
