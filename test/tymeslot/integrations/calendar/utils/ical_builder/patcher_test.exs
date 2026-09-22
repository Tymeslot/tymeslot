defmodule Tymeslot.Integrations.Calendar.ICalBuilder.PatcherTest do
  @moduledoc """
  What survives an edit of an event Tymeslot did not write.

  `build_simple_event/3` serialises Tymeslot's payload and nothing else, so
  applying it to a synced event replaces its `ATTENDEE` block with Tymeslot's
  own and drops everything the cache does not model. The patcher exists so the
  stored document goes back to the server with only the edited properties
  rewritten; these tests pin what it may touch and, more importantly, what it
  may not.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder

  # A VEVENT as a CalDAV server returns it: attendees with their scheduling
  # parameters, an organiser, an alarm, and properties Tymeslot never reads.
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
  LOCATION:Room 4\r
  SEQUENCE:3\r
  CATEGORIES:WORK,TEAM\r
  ORGANIZER;CN=Dana:mailto:dana@example.com\r
  ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada:mailto:ada@example.com\r
  ATTENDEE;PARTSTAT=TENTATIVE;RSVP=TRUE;CUTYPE=INDIVIDUAL:mailto:bob@example.com\r
  X-MOZ-GENERATION:7\r
  BEGIN:VALARM\r
  TRIGGER:-PT10M\r
  ACTION:DISPLAY\r
  DESCRIPTION:Reminder\r
  END:VALARM\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  # The patched document goes back out folded, so it is read back the way a
  # calendar client reads it: as logical content lines.
  defp lines(ical), do: LineFolder.unfold_lines(ical)

  defp wire_lines(ical), do: String.split(ical, "\r\n")

  describe "patch_event_properties/3 on an event Tymeslot did not write" do
    test "renaming it keeps both ATTENDEE lines with their parameters" do
      patched = ICalBuilder.patch_event_properties(@foreign_event, %{summary: "Renamed"})

      assert "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada:mailto:ada@example.com" in lines(
               patched
             )

      assert "ATTENDEE;PARTSTAT=TENTATIVE;RSVP=TRUE;CUTYPE=INDIVIDUAL:mailto:bob@example.com" in lines(
               patched
             )

      assert "SUMMARY:Renamed" in lines(patched)
      refute "SUMMARY:Sprint review" in lines(patched)
    end

    test "renaming it adds no CONTACT line, whatever the payload says about attendees" do
      patched =
        ICalBuilder.patch_event_properties(@foreign_event, %{
          summary: "Renamed",
          attendees: [%{"email" => "ada@example.com", "name" => "Ada"}]
        })

      refute patched =~ "CONTACT:"
    end

    test "properties the payload does not model come back untouched" do
      patched = ICalBuilder.patch_event_properties(@foreign_event, %{summary: "Renamed"})
      patched_lines = lines(patched)

      for line <- [
            "SEQUENCE:3",
            "CATEGORIES:WORK,TEAM",
            "ORGANIZER;CN=Dana:mailto:dana@example.com",
            "X-MOZ-GENERATION:7",
            "UID:foreign-event-1"
          ] do
        assert line in patched_lines
      end
    end

    test "its alarm survives an edit that says nothing about reminders" do
      patched = ICalBuilder.patch_event_properties(@foreign_event, %{summary: "Renamed"})

      assert patched =~ "BEGIN:VALARM"
      assert "TRIGGER:-PT10M" in lines(patched)
    end

    test "a property the payload leaves out is not rewritten" do
      patched = ICalBuilder.patch_event_properties(@foreign_event, %{summary: "Renamed"})

      assert "LOCATION:Room 4" in lines(patched)
    end
  end

  describe "patch_event_properties/3 property replacement" do
    test "moving the event replaces DTSTART and DTEND" do
      patched =
        ICalBuilder.patch_event_properties(@foreign_event, %{
          start_time: ~U[2026-09-11 14:00:00Z],
          end_time: ~U[2026-09-11 15:00:00Z],
          all_day: false
        })

      assert "DTSTART:20260911T140000Z" in lines(patched)
      assert "DTEND:20260911T150000Z" in lines(patched)
      refute "DTSTART:20260910T090000Z" in lines(patched)
    end

    test "a DTEND replaces a stored DURATION, which RFC 5545 forbids beside it" do
      with_duration =
        String.replace(@foreign_event, "DTEND:20260910T100000Z\r\n", "DURATION:PT1H\r\n")

      patched =
        ICalBuilder.patch_event_properties(with_duration, %{
          start_time: ~U[2026-09-10 09:00:00Z],
          end_time: ~U[2026-09-10 11:00:00Z],
          all_day: false
        })

      assert "DTEND:20260910T110000Z" in lines(patched)
      refute patched =~ "DURATION:"
    end

    test "making the event all-day rewrites its timing as DATE values" do
      patched =
        ICalBuilder.patch_event_properties(@foreign_event, %{
          start_time: ~D[2026-09-10],
          end_time: ~D[2026-09-11],
          all_day: true
        })

      assert "DTSTART;VALUE=DATE:20260910" in lines(patched)
      assert "DTEND;VALUE=DATE:20260911" in lines(patched)
      refute "DTSTART:20260910T090000Z" in lines(patched)
      refute "DTEND:20260910T100000Z" in lines(patched)
    end

    test "clearing a field the payload carries deletes its property" do
      recurring =
        String.replace(
          @foreign_event,
          "SUMMARY:Sprint review\r\n",
          "SUMMARY:Sprint review\r\nRRULE:FREQ=WEEKLY;BYDAY=TH\r\n"
        )

      assert recurring =~ "RRULE:"

      patched = ICalBuilder.patch_event_properties(recurring, %{recurrence_rule: nil})

      refute patched =~ "RRULE:"
    end

    test "supplying reminders replaces the stored alarms" do
      patched =
        ICalBuilder.patch_event_properties(@foreign_event, %{
          reminders: [%{method: :email, minutes_before: 45}]
        })

      assert "TRIGGER:-PT45M" in lines(patched)
      assert "ACTION:EMAIL" in lines(patched)
      refute "TRIGGER:-PT10M" in lines(patched)
    end

    test "supplying no reminders at all removes the stored alarms" do
      patched = ICalBuilder.patch_event_properties(@foreign_event, %{reminders: []})

      refute patched =~ "BEGIN:VALARM"
    end

    test "the revision stamp is moved on" do
      patched = ICalBuilder.patch_event_properties(@foreign_event, %{summary: "Renamed"})

      refute "DTSTAMP:20260901T090000Z" in lines(patched)
      assert Enum.count(lines(patched), &String.starts_with?(&1, "DTSTAMP:")) == 1
    end

    test "a long value comes back folded per RFC 5545 §3.1" do
      summary = String.duplicate("a", 200)

      patched = ICalBuilder.patch_event_properties(@foreign_event, %{summary: summary})

      assert Enum.all?(wire_lines(patched), &(byte_size(&1) <= 75))
      assert "SUMMARY:#{summary}" in lines(patched)
    end

    test "a folded line the server sent is read as one property" do
      folded =
        String.replace(
          @foreign_event,
          "CATEGORIES:WORK,TEAM\r\n",
          "CATEGORIES:WORK,TEAM,A-VERY-LONG-CATEGORY-NAME-THAT-THE-SERVER-FOLDED-ACR\r\n OSS-TWO-LINES\r\n"
        )

      patched = ICalBuilder.patch_event_properties(folded, %{summary: "Renamed"})

      assert "CATEGORIES:WORK,TEAM,A-VERY-LONG-CATEGORY-NAME-THAT-THE-SERVER-FOLDED-ACROSS-TWO-LINES" in lines(
               patched
             )
    end
  end

  describe "patch_event_properties/3 on an event Tymeslot wrote" do
    @tymeslot_event """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Tymeslot//CalDAV Client//EN\r
    BEGIN:VEVENT\r
    UID:booking-1\r
    DTSTAMP:20260901T090000Z\r
    DTSTART:20260910T090000Z\r
    DTEND:20260910T100000Z\r
    SUMMARY:Intro call\r
    CONTACT:Ada <ada@example.com>\r
    ORGANIZER;SCHEDULE-AGENT=CLIENT:mailto:host@example.com\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    test "its CONTACT lines are rewritten, since no ATTENDEE block is at risk" do
      patched =
        ICalBuilder.patch_event_properties(@tymeslot_event, %{
          attendees: [%{"email" => "bob@example.com", "name" => "Bob"}]
        })

      assert "CONTACT:Bob <bob@example.com>" in lines(patched)
      refute "CONTACT:Ada <ada@example.com>" in lines(patched)
      refute patched =~ "ATTENDEE"
    end

    # An event written before Tymeslot advertised attendees at all, now edited
    # against a server that accepts them: it converges on the new property
    # rather than carrying the attendee under both spellings.
    test "a stored CONTACT becomes an ATTENDEE in :attendee mode" do
      patched =
        ICalBuilder.patch_event_properties(
          @tymeslot_event,
          %{attendees: [%{"email" => "bob@example.com", "name" => "Bob"}]},
          :attendee
        )

      assert "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE;CN=Bob:mailto:bob@example.com" in lines(
               patched
             )

      refute Enum.any?(lines(patched), &String.starts_with?(&1, "CONTACT"))
    end
  end

  describe "patch_event_properties/3 on an ATTENDEE block Tymeslot wrote" do
    @marked_event """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Tymeslot//CalDAV Client//EN\r
    BEGIN:VEVENT\r
    UID:booking-2\r
    DTSTAMP:20260901T090000Z\r
    DTSTART:20260910T090000Z\r
    DTEND:20260910T100000Z\r
    SUMMARY:Intro call\r
    ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE;CN=Ada:mailto:ada@example.com\r
    X-TYMESLOT-ATTENDEES:1\r
    ORGANIZER;SCHEDULE-AGENT=CLIENT:mailto:host@example.com\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    test "the marker lets its own block be rewritten" do
      patched =
        ICalBuilder.patch_event_properties(
          @marked_event,
          %{attendees: [%{"email" => "bob@example.com", "name" => "Bob"}]},
          :attendee
        )

      assert "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE;CN=Bob:mailto:bob@example.com" in lines(
               patched
             )

      refute patched =~ "ada@example.com"
    end

    test "the marker is written once, not accumulated on every edit" do
      patched =
        ICalBuilder.patch_event_properties(
          @marked_event,
          %{attendees: [%{"email" => "bob@example.com", "name" => "Bob"}]},
          :attendee
        )

      assert Enum.count(lines(patched), &(&1 == "X-TYMESLOT-ATTENDEES:1")) == 1
    end

    # The guard is the marker, not the absence of an ATTENDEE block: an
    # unmarked block belongs to the organiser's own client, and rewriting it
    # would reset the PARTSTAT that client is tracking.
    test "an unmarked ATTENDEE block is still left alone in :attendee mode" do
      patched =
        ICalBuilder.patch_event_properties(
          @foreign_event,
          %{
            summary: "Renamed",
            attendees: [%{"email" => "bob@example.com", "name" => "Bob"}]
          },
          :attendee
        )

      assert "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada:mailto:ada@example.com" in lines(
               patched
             )

      assert "SUMMARY:Renamed" in lines(patched)
      refute patched =~ "bob@example.com"
      refute patched =~ "X-TYMESLOT-ATTENDEES"
    end
  end

  describe "patch_event_properties/3 on components it must not touch" do
    @with_vtimezone """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    BEGIN:VTIMEZONE\r
    TZID:Europe/Berlin\r
    BEGIN:DAYLIGHT\r
    TZOFFSETFROM:+0100\r
    TZOFFSETTO:+0200\r
    DTSTART:19700329T020000\r
    RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r
    END:DAYLIGHT\r
    END:VTIMEZONE\r
    BEGIN:VEVENT\r
    UID:tz-event-1\r
    DTSTART;TZID=Europe/Berlin:20260910T110000\r
    DTEND;TZID=Europe/Berlin:20260910T120000\r
    SUMMARY:Standup\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    test "a VTIMEZONE keeps its own DTSTART and RRULE" do
      patched =
        ICalBuilder.patch_event_properties(@with_vtimezone, %{
          start_time: ~U[2026-09-10 12:00:00Z],
          end_time: ~U[2026-09-10 13:00:00Z],
          all_day: false,
          recurrence_rule: nil
        })

      patched_lines = lines(patched)

      assert "DTSTART:19700329T020000" in patched_lines
      assert "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU" in patched_lines
      assert "DTSTART:20260910T120000Z" in patched_lines
      refute "DTSTART;TZID=Europe/Berlin:20260910T110000" in patched_lines
    end

    @series """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    BEGIN:VEVENT\r
    UID:series-1\r
    DTSTART:20260910T090000Z\r
    DTEND:20260910T100000Z\r
    RRULE:FREQ=WEEKLY\r
    SUMMARY:Weekly sync\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:series-1\r
    RECURRENCE-ID:20260917T090000Z\r
    DTSTART:20260917T140000Z\r
    DTEND:20260917T150000Z\r
    SUMMARY:Weekly sync (moved)\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    test "an occurrence override keeps its own timing and title" do
      patched =
        ICalBuilder.patch_event_properties(@series, %{
          summary: "Renamed",
          start_time: ~U[2026-09-10 11:00:00Z],
          end_time: ~U[2026-09-10 12:00:00Z],
          all_day: false
        })

      patched_lines = lines(patched)

      assert "SUMMARY:Renamed" in patched_lines
      assert "DTSTART:20260910T110000Z" in patched_lines

      assert "SUMMARY:Weekly sync (moved)" in patched_lines
      assert "DTSTART:20260917T140000Z" in patched_lines
      assert "RECURRENCE-ID:20260917T090000Z" in patched_lines
    end
  end
end
