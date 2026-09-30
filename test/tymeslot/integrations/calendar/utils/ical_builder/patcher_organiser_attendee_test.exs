defmodule Tymeslot.Integrations.Calendar.ICalBuilder.PatcherOrganiserAttendeeTest do
  @moduledoc """
  How the patcher treats the organiser's own `ATTENDEE` line for a server
  that adds its calendar's owner to any event not already listing them.

  Issue #151: Open-Xchange writes the owner it adds under the account's
  primary address, so an organiser booking from an alias saw their login
  address join the meeting. A rewrite that dropped the organiser's line would
  bring that address straight back.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder

  # An event another client organised, listing Dana as organiser and never as
  # an attendee.
  @foreign_event """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  PRODID:-//Mozilla.org/NONSGML Mozilla Calendar V1.1//EN\r
  BEGIN:VEVENT\r
  UID:foreign-event-1\r
  DTSTAMP:20260901T090000Z\r
  DTSTART:20260910T090000Z\r
  DTEND:20260910T100000Z\r
  SUMMARY:Sprint review\r
  ORGANIZER;CN=Dana:mailto:dana@example.com\r
  ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada:mailto:ada@example.com\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  defp lines(ical), do: LineFolder.unfold_lines(ical)

  defp ox_attendee_lines(ical),
    do: Enum.filter(lines(ical), &String.starts_with?(&1, "ATTENDEE"))

  # Open-Xchange puts its calendar's owner back under their
  # primary address the moment no ATTENDEE names them, so in
  # `:organiser_attendee` mode the organiser's line is never the one a
  # rewrite drops, and Tymeslot's own block gains it when it lacks one.
  describe "patch_event_properties/3 in :organiser_attendee mode" do
    @organiser_line "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=CHAIR;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:host@example.com"

    @ox_event """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Tymeslot//CalDAV Client//EN\r
    BEGIN:VEVENT\r
    UID:booking-ox\r
    DTSTAMP:20260901T090000Z\r
    DTSTART:20260910T090000Z\r
    DTEND:20260910T100000Z\r
    SUMMARY:Intro call\r
    ATTENDEE;CN=Ada;PARTSTAT=NEEDS-ACTION;ROLE=REQ-PARTICIPANT;RSVP=FALSE:mailto:ada@example.com\r
    ATTENDEE;CN=Host;PARTSTAT=ACCEPTED;ROLE=CHAIR;CUTYPE=INDIVIDUAL;RSVP=FALSE:mailto:host@example.com\r
    ORGANIZER;CN=Host:mailto:host@example.com\r
    X-TYMESLOT-ATTENDEES:1\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    test "the organiser's line stays when the payload's list leaves them out" do
      patched =
        ICalBuilder.patch_event_properties(
          @ox_event,
          %{attendees: [%{"email" => "ada@example.com"}]},
          :organiser_attendee
        )

      assert "ATTENDEE;CN=Host;PARTSTAT=ACCEPTED;ROLE=CHAIR;CUTYPE=INDIVIDUAL;RSVP=FALSE:mailto:host@example.com" in ox_attendee_lines(
               patched
             )
    end

    test "removing every guest still leaves the organiser listed" do
      patched =
        ICalBuilder.patch_event_properties(@ox_event, %{attendees: []}, :organiser_attendee)

      assert [line] = ox_attendee_lines(patched)
      assert line =~ "mailto:host@example.com"
    end

    test "the same removal drops the organiser's line in :attendee mode" do
      patched = ICalBuilder.patch_event_properties(@ox_event, %{attendees: []}, :attendee)

      assert ox_attendee_lines(patched) == []
    end

    test "Tymeslot's own block that lacks the organiser gains their line" do
      without_organiser =
        String.replace(
          @ox_event,
          "ATTENDEE;CN=Host;PARTSTAT=ACCEPTED;ROLE=CHAIR;CUTYPE=INDIVIDUAL;RSVP=FALSE:mailto:host@example.com\r\n",
          ""
        )

      patched =
        ICalBuilder.patch_event_properties(
          without_organiser,
          %{attendees: [%{"email" => "ada@example.com"}]},
          :organiser_attendee
        )

      assert @organiser_line in ox_attendee_lines(patched)
      assert "X-TYMESLOT-ATTENDEES:1" in lines(patched)
    end

    test "an organiser the payload lists as a guest is written once, as the chair" do
      without_organiser =
        String.replace(
          @ox_event,
          "ATTENDEE;CN=Host;PARTSTAT=ACCEPTED;ROLE=CHAIR;CUTYPE=INDIVIDUAL;RSVP=FALSE:mailto:host@example.com\r\n",
          ""
        )

      patched =
        ICalBuilder.patch_event_properties(
          without_organiser,
          %{attendees: [%{"email" => "ada@example.com"}, %{"email" => "HOST@example.com"}]},
          :organiser_attendee
        )

      assert Enum.filter(ox_attendee_lines(patched), &(&1 =~ ~r/mailto:host@example\.com$/i)) ==
               [@organiser_line]
    end

    test "a new guest is written as a client-scheduled participant" do
      patched =
        ICalBuilder.patch_event_properties(
          @ox_event,
          %{attendees: [%{"email" => "ada@example.com"}, %{"email" => "cleo@example.com"}]},
          :organiser_attendee
        )

      assert "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE:mailto:cleo@example.com" in ox_attendee_lines(
               patched
             )
    end

    test "an event someone else organised keeps its organiser but gains no line for them" do
      patched =
        ICalBuilder.patch_event_properties(
          @foreign_event,
          %{attendees: [%{"email" => "ada@example.com"}]},
          :organiser_attendee
        )

      assert "ORGANIZER;CN=Dana:mailto:dana@example.com" in lines(patched)
      refute Enum.any?(ox_attendee_lines(patched), &(&1 =~ "mailto:dana@example.com"))
    end
  end
end
