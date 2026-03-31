defmodule Tymeslot.Integrations.Calendar.CalDAV.EventProcessorTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.CalendarEventCacheSchema
  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Repo

  describe "clean_etag/1" do
    test "strips surrounding double-quotes" do
      assert EventProcessor.clean_etag("\"abc123\"") == "abc123"
    end

    test "strips surrounding whitespace" do
      assert EventProcessor.clean_etag("  abc123  ") == "abc123"
    end

    test "strips whitespace then quotes" do
      assert EventProcessor.clean_etag("  \"abc123\"  ") == "abc123"
    end

    test "leaves etags without quotes unchanged" do
      assert EventProcessor.clean_etag("abc123") == "abc123"
    end

    test "returns nil for non-binary input" do
      assert EventProcessor.clean_etag(nil) == nil
      assert EventProcessor.clean_etag(42) == nil
    end
  end

  describe "parse_ical_from_string/1" do
    @valid_ical """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//Test//EN
    BEGIN:VEVENT
    UID:test-uid-001@example.com
    DTSTART:20300315T100000Z
    DTEND:20300315T110000Z
    SUMMARY:Team Meeting
    END:VEVENT
    END:VCALENDAR
    """

    test "parses a valid iCalendar string and returns the first event" do
      assert {:ok, event} = EventProcessor.parse_ical_from_string(@valid_ical)
      assert Map.get(event, :uid) == "test-uid-001@example.com"
      assert Map.get(event, :summary) == "Team Meeting"
    end

    test "returns {:error, :empty_data} for nil" do
      assert EventProcessor.parse_ical_from_string(nil) == {:error, :empty_data}
    end

    test "returns {:error, :empty_data} for empty string" do
      assert EventProcessor.parse_ical_from_string("") == {:error, :empty_data}
    end

    test "returns {:error, :empty_data} for non-binary input" do
      assert EventProcessor.parse_ical_from_string(42) == {:error, :empty_data}
    end

    test "parses attendees from an iCalendar string" do
      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:with-attendees@example.com
      DTSTART:20300315T100000Z
      DTEND:20300315T110000Z
      SUMMARY:Group Meeting
      ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com
      ATTENDEE;CN=Bob;PARTSTAT=TENTATIVE:mailto:bob@example.com
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = EventProcessor.parse_ical_from_string(ical)
      assert [alice, bob] = Map.get(event, :attendees)
      assert alice["email"] == "alice@example.com"
      assert alice["name"] == "Alice"
      assert alice["status"] == "accepted"
      assert bob["email"] == "bob@example.com"
      assert bob["status"] == "tentative"
    end

    test "parses recurrence rule from an iCalendar string" do
      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:recurring@example.com
      DTSTART:20300315T100000Z
      DTEND:20300315T110000Z
      SUMMARY:Weekly Sync
      RRULE:FREQ=WEEKLY;INTERVAL=1
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = EventProcessor.parse_ical_from_string(ical)
      assert Map.get(event, :recurrence_rule) == "FREQ=WEEKLY;INTERVAL=1"
    end

    test "maps TRANSP:TRANSPARENT to transparency field" do
      ical = """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:free-event@example.com
      DTSTART:20300315T100000Z
      DTEND:20300315T110000Z
      SUMMARY:Out of Office
      TRANSP:TRANSPARENT
      END:VEVENT
      END:VCALENDAR
      """

      assert {:ok, event} = EventProcessor.parse_ical_from_string(ical)
      assert Map.get(event, :transparency) == "transparent"
    end
  end

  describe "process_events/2 - all_day detection" do
    test "sets all_day: true for a VALUE=DATE event (Date start_time)" do
      integration = insert(:calendar_integration, provider: "caldav")

      event = %{
        uid: "allday-date@example.com",
        href: "/calendars/user/default/allday-date.ics",
        summary: "Holiday",
        start_time: ~D[2030-03-15],
        end_time: ~D[2030-03-16]
      }

      EventProcessor.process_events(integration, [event])

      cached = Repo.get_by(CalendarEventCacheSchema, uid: "allday-date@example.com")
      assert cached.all_day == true
    end

    test "sets all_day: true for a midnight-UTC DATETIME event (Radicale whole-day block pattern)" do
      integration = insert(:calendar_integration, provider: "caldav")

      event = %{
        uid: "allday-utcmidnight@example.com",
        href: "/calendars/user/default/allday-utcmidnight.ics",
        summary: "Blocked Day",
        start_time: ~U[2030-03-15 00:00:00Z],
        end_time: ~U[2030-03-16 00:00:00Z]
      }

      EventProcessor.process_events(integration, [event])

      cached = Repo.get_by(CalendarEventCacheSchema, uid: "allday-utcmidnight@example.com")
      assert cached.all_day == true
    end

    test "sets all_day: false for a timed event that happens to start at midnight UTC" do
      integration = insert(:calendar_integration, provider: "caldav")

      event = %{
        uid: "midnight-start-timed@example.com",
        href: "/calendars/user/default/midnight-start-timed.ics",
        summary: "Late Night Event",
        start_time: ~U[2030-03-15 00:00:00Z],
        end_time: ~U[2030-03-15 02:00:00Z]
      }

      EventProcessor.process_events(integration, [event])

      cached = Repo.get_by(CalendarEventCacheSchema, uid: "midnight-start-timed@example.com")
      assert cached.all_day == false
    end

    test "sets all_day: false for a normal timed event" do
      integration = insert(:calendar_integration, provider: "caldav")

      event = %{
        uid: "timed-event@example.com",
        href: "/calendars/user/default/timed-event.ics",
        summary: "Team Meeting",
        start_time: ~U[2030-03-15 10:00:00Z],
        end_time: ~U[2030-03-15 11:00:00Z]
      }

      EventProcessor.process_events(integration, [event])

      cached = Repo.get_by(CalendarEventCacheSchema, uid: "timed-event@example.com")
      assert cached.all_day == false
    end
  end

  describe "process_events/2 - cache attr mapping" do
    test "stores status 'free' for a transparent (TRANSP:TRANSPARENT) CalDAV event" do
      integration = insert(:calendar_integration, provider: "caldav")

      event = %{
        uid: "free-event@example.com",
        href: "/calendars/user/default/free-event.ics",
        summary: "Out of Office",
        start_time: ~U[2030-03-15 10:00:00Z],
        end_time: ~U[2030-03-15 11:00:00Z],
        transparency: "transparent"
      }

      EventProcessor.process_events(integration, [event])

      cached = Repo.get_by(CalendarEventCacheSchema, uid: "free-event@example.com")
      assert cached.status == "free"
    end

    test "stores status 'confirmed' for an opaque (default) CalDAV event" do
      integration = insert(:calendar_integration, provider: "caldav")

      event = %{
        uid: "confirmed-event@example.com",
        href: "/calendars/user/default/confirmed-event.ics",
        summary: "Team Meeting",
        start_time: ~U[2030-03-15 10:00:00Z],
        end_time: ~U[2030-03-15 11:00:00Z],
        transparency: "opaque"
      }

      EventProcessor.process_events(integration, [event])

      cached = Repo.get_by(CalendarEventCacheSchema, uid: "confirmed-event@example.com")
      assert cached.status == "confirmed"
    end
  end
end
