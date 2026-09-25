defmodule Tymeslot.Integrations.Calendar.ICalNormaliserAttendeesTest do
  @moduledoc """
  The attendees an iCalendar event is cached with, from the `ATTENDEE` lines
  on the wire through `ICalParser` and `ICalNormaliser`, the path both CalDAV
  and subscribed ICS feeds take.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations

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
end
