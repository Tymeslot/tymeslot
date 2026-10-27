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

  # The account owns the organiser's address.
  @ox_mode {:organiser_attendee, ["login@mailbox.org", "host@example.com"]}

  # The reporter's account: the organiser's custom domain is not among its
  # addresses.
  @custom_domain_mode {:organiser_attendee, ["login@mailbox.org"]}

  defp lines(ical), do: LineFolder.unfold_lines(ical)

  defp ox_attendee_lines(ical),
    do: Enum.filter(lines(ical), &String.starts_with?(&1, "ATTENDEE"))

  # Open-Xchange puts its calendar's owner back under their
  # primary address the moment no ATTENDEE names them, so in
  # `{:organiser_attendee, _}` mode the organiser's line is never the one a
  # rewrite drops, and Tymeslot's own block gains it when it lacks one.
  describe "patch_event_properties/3 in {:organiser_attendee, _} mode" do
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
          @ox_mode
        )

      assert "ATTENDEE;CN=Host;PARTSTAT=ACCEPTED;ROLE=CHAIR;CUTYPE=INDIVIDUAL;RSVP=FALSE:mailto:host@example.com" in ox_attendee_lines(
               patched
             )
    end

    test "removing every guest still leaves the organiser listed" do
      patched =
        ICalBuilder.patch_event_properties(@ox_event, %{attendees: []}, @ox_mode)

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
          @ox_mode
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
          @ox_mode
        )

      assert Enum.filter(ox_attendee_lines(patched), &(&1 =~ ~r/mailto:host@example\.com$/i)) ==
               [@organiser_line]
    end

    test "a new guest is written as a client-scheduled participant" do
      patched =
        ICalBuilder.patch_event_properties(
          @ox_event,
          %{attendees: [%{"email" => "ada@example.com"}, %{"email" => "cleo@example.com"}]},
          @ox_mode
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
          @ox_mode
        )

      assert "ORGANIZER;CN=Dana:mailto:dana@example.com" in lines(patched)
      refute Enum.any?(ox_attendee_lines(patched), &(&1 =~ "mailto:dana@example.com"))
    end

    test "an organiser the account does not own gains the owner's line under its address" do
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
          @custom_domain_mode
        )

      assert Enum.map(ox_attendee_lines(patched), &String.replace(&1, ~r/^.*:mailto:/, "")) ==
               ["ada@example.com", "login@mailbox.org"]
    end

    # What an earlier fix for #151 left behind: the organiser listed beside
    # the owner the server added anyway.
    test "an event listing the organiser beside the owner loses the organiser's line" do
      duplicated =
        String.replace(
          @ox_event,
          "ORGANIZER;",
          "ATTENDEE;CN=Host;PARTSTAT=ACCEPTED;CUTYPE=INDIVIDUAL:mailto:login@mailbox.org\r\nORGANIZER;"
        )

      patched =
        ICalBuilder.patch_event_properties(
          duplicated,
          %{attendees: [%{"email" => "ada@example.com"}]},
          @custom_domain_mode
        )

      assert Enum.map(ox_attendee_lines(patched), &String.replace(&1, ~r/^.*:mailto:/, "")) ==
               ["ada@example.com", "login@mailbox.org"]
    end

    # Only Tymeslot's own block drops the organiser's line for the owner's.
    test "an event someone else organised keeps the line naming its organiser" do
      listed =
        String.replace(
          @foreign_event,
          "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada",
          "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=CHAIR;CN=Dana:mailto:dana@example.com\r\nATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada"
        )

      patched =
        ICalBuilder.patch_event_properties(
          listed,
          %{attendees: [%{"email" => "ada@example.com"}]},
          @custom_domain_mode
        )

      assert "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=CHAIR;CN=Dana:mailto:dana@example.com" in ox_attendee_lines(
               patched
             )
    end
  end
end
