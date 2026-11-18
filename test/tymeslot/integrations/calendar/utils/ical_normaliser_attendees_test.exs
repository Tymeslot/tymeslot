defmodule Tymeslot.Integrations.Calendar.ICalNormaliserAttendeesTest do
  @moduledoc """
  The attendees an iCalendar event is cached with, from the `ATTENDEE` lines
  on the wire through `ICalParser` and `ICalNormaliser`, the path both CalDAV
  and subscribed ICS feeds take.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.ICalParser

  @context %{
    calendar_integration_id: 1,
    provider_calendar_id: "/cal/primary",
    synced_at: ~U[2026-09-01 00:00:00Z]
  }

  defp cached_attendees(attendee_lines) do
    ical = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:attendees@example.com
    DTSTART:20300115T100000Z
    DTEND:20300115T110000Z
    SUMMARY:Team Standup
    #{attendee_lines}
    END:VEVENT
    END:VCALENDAR
    """

    {:ok, raw_events} = ICalParser.parse(ical)
    {:ok, [event]} = ICalNormaliser.normalise_events(raw_events, @context, :caldav)
    event.attendees
  end

  test "reads CN and PARTSTAT into the canonical attendee" do
    assert cached_attendees("ATTENDEE;CN=Alice Smith;PARTSTAT=ACCEPTED:mailto:alice@example.com") ==
             [
               %{
                 email: "alice@example.com",
                 display_name: "Alice Smith",
                 response_status: :accepted,
                 optional: false
               }
             ]
  end

  test "maps each reply a CalDAV server reports" do
    attendees =
      cached_attendees("""
      ATTENDEE;PARTSTAT=DECLINED:mailto:bob@example.com
      ATTENDEE;PARTSTAT=TENTATIVE:mailto:carol@example.com
      ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:dan@example.com
      """)

    assert Enum.map(attendees, & &1.response_status) == [:declined, :tentative, :needs_action]
  end

  # RFC 5545 §3.2.12 makes NEEDS-ACTION the default, and DELEGATED is not a
  # reply any provider can carry back.
  test "reads a missing or delegated PARTSTAT as needs_action" do
    attendees =
      cached_attendees("""
      ATTENDEE:mailto:erin@example.com
      ATTENDEE;PARTSTAT=DELEGATED:mailto:frank@example.com
      """)

    assert Enum.map(attendees, & &1.response_status) == [:needs_action, :needs_action]
    assert Enum.map(attendees, & &1.display_name) == [nil, nil]
  end

  describe "guests written as CONTACT lines" do
    # How a server that would invite an ATTENDEE itself (Zimbra, cPanel, and
    # SOGo, whose `/SOGo/dav/` URL reads as Zimbra's) holds an event the
    # calendar created with guests: re-serialised by the server, without the
    # lines Tymeslot wrote for the server alone.
    defp cached(uid, property_lines) do
      ical = """
      BEGIN:VCALENDAR
      PRODID:-//Tymeslot//CalDAV Client//EN
      VERSION:2.0
      BEGIN:VEVENT
      UID:#{uid}
      DTSTART:20301119T100000Z
      DTEND:20301119T110000Z
      SUMMARY:Planning
      TRANSP:OPAQUE
      #{property_lines}
      CLASS:PUBLIC
      END:VEVENT
      END:VCALENDAR
      """

      {:ok, raw_events} = ICalParser.parse(ical)
      {:ok, [event]} = ICalNormaliser.normalise_events(raw_events, @context, :caldav)
      event.attendees
    end

    test "are the guests of an event Tymeslot wrote" do
      assert [
               %{email: "ada@example.com", display_name: "Ada Lovelace", response_status: nil},
               %{email: "grace@example.com", display_name: "Hopper, Grace", response_status: nil},
               %{email: "ops@example.com", display_name: nil, response_status: nil}
             ] =
               cached("planning@tymeslot.com", """
               CONTACT:Ada Lovelace <ada@example.com>
               CONTACT:Hopper\\, Grace <grace@example.com>
               CONTACT:ops@example.com
               """)
    end

    test "come back as the guests the calendar wrote them from" do
      guests = [
        %{email: "ada@example.com", display_name: "Ada Lovelace"},
        %{email: "grace@example.com", display_name: nil}
      ]

      ical =
        ICalBuilder.build_simple_event(
          "roundtrip@tymeslot.com",
          %{
            summary: "Planning",
            start_time: ~U[2030-11-19 10:00:00Z],
            end_time: ~U[2030-11-19 11:00:00Z],
            attendees: guests
          },
          :contact
        )

      refute ical =~ "ATTENDEE"

      {:ok, raw_events} = ICalParser.parse(ical)
      {:ok, [event]} = ICalNormaliser.normalise_events(raw_events, @context, :caldav)

      assert Enum.map(event.attendees, &Map.take(&1, [:email, :display_name])) == guests
    end

    test "are nobody's guests on an event someone else wrote" do
      assert cached("dentist@example.com", "CONTACT:Front desk <desk@example.com>") == []
    end

    test "are not read beside the ATTENDEE lines an event names" do
      assert [%{email: "ada@example.com"}] =
               cached("planning@tymeslot.com", """
               ATTENDEE:mailto:ada@example.com
               CONTACT:Front desk <desk@example.com>
               """)
    end

    test "keep their name when a quoted parameter holds a colon" do
      assert [%{email: "ada@example.com", display_name: "Ada Lovelace"}] =
               cached(
                 "planning@tymeslot.com",
                 ~s(CONTACT;ALTREP="ldap://ldap.example.com:6666/o=ABC":Ada Lovelace <ada@example.com>)
               )
    end

    test "are read whatever the case of the property name" do
      assert [%{email: "ada@example.com", display_name: "Ada Lovelace"}] =
               cached("planning@tymeslot.com", "Contact:Ada Lovelace <ada@example.com>")
    end

    test "are matched by their address without a mailto: prefix, in any case" do
      assert [
               %{email: "ada@example.com", display_name: "Ada Lovelace"},
               %{email: "grace@example.com", display_name: nil}
             ] =
               cached("planning@tymeslot.com", """
               CONTACT:Ada Lovelace <MAILTO:ada@example.com>
               CONTACT:mailto:grace@example.com
               """)
    end

    test "naming no address are left out" do
      assert cached("planning@tymeslot.com", "CONTACT:Front desk, ext. 12") == []
    end
  end

  describe "an attendee no reply was asked of (RSVP=FALSE)" do
    test "has no reply to show rather than one pending" do
      attendees =
        cached_attendees("""
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=FALSE:mailto:grace@example.com
        ATTENDEE;RSVP=FALSE:mailto:heidi@example.com
        """)

      assert Enum.map(attendees, & &1.response_status) == [nil, nil]
    end

    test "still shows a reply that came back anyway" do
      attendees =
        cached_attendees("""
        ATTENDEE;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:ivan@example.com
        ATTENDEE;PARTSTAT=DECLINED;RSVP=FALSE:mailto:judy@example.com
        """)

      assert Enum.map(attendees, & &1.response_status) == [:accepted, :declined]
    end

    test "is told apart from one asked to reply, or not told either way" do
      attendees =
        cached_attendees("""
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:mallory@example.com
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:niaj@example.com
        """)

      assert Enum.map(attendees, & &1.response_status) == [:needs_action, :needs_action]
    end

    test "is how a guest Tymeslot itself wrote to a plain event reads back" do
      ical =
        ICalBuilder.build_simple_event(
          "plain@tymeslot.com",
          %{
            summary: "Planning",
            start_time: ~U[2030-01-15 10:00:00Z],
            end_time: ~U[2030-01-15 11:00:00Z],
            attendees: ["guest@example.com"]
          },
          :attendee
        )

      {:ok, raw_events} = ICalParser.parse(ical)
      {:ok, [event]} = ICalNormaliser.normalise_events(raw_events, @context, :caldav)

      assert [%{email: "guest@example.com", response_status: nil}] =
               Enum.filter(event.attendees, &(&1.email == "guest@example.com"))
    end
  end
end
