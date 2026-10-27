defmodule Tymeslot.Integrations.Calendar.ICalAlarmsReadTest do
  @moduledoc """
  An iCalendar event's `VALARM` blocks on the read path both CalDAV and
  subscribed ICS feeds take (`ICalParser`, then `ICalNormaliser`): the alarms
  become the cached reminders, and their own properties are never read as
  the event's.
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

  defp parsed(event_lines) do
    {:ok, [event]} =
      ICalParser.parse("""
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:alarms@example.com
      #{event_lines}
      END:VEVENT
      END:VCALENDAR
      """)

    event
  end

  defp cached(event_lines) do
    {:ok, [event]} =
      ICalNormaliser.normalise_events([parsed(event_lines)], @context, :caldav)

    event
  end

  defp alarm(trigger_line, action \\ "DISPLAY") do
    """
    BEGIN:VALARM
    ACTION:#{action}
    #{trigger_line}
    DESCRIPTION:Reminder
    END:VALARM
    """
  end

  defp reminders_for(alarms) do
    cached("""
    DTSTART:20300115T100000Z
    DTEND:20300115T110000Z
    SUMMARY:Planning
    #{alarms}
    """).reminders
  end

  describe "the event's own properties" do
    test "an alarm's DESCRIPTION is not the description of an event with none" do
      event =
        parsed("""
        DTSTART:20300115T100000Z
        DTEND:20300115T110000Z
        SUMMARY:Planning
        #{alarm("TRIGGER:-PT15M")}
        """)

      assert event.description == nil
    end

    test "an event keeps its own DESCRIPTION when it comes after the alarm" do
      event =
        parsed("""
        DTSTART:20300115T100000Z
        DTEND:20300115T110000Z
        #{alarm("TRIGGER:-PT15M")}
        DESCRIPTION:Quarterly numbers
        """)

      assert event.description == "Quarterly numbers"
    end

    test "an alarm's SUMMARY is not the summary of an event with none" do
      event =
        parsed("""
        DTSTART:20300115T100000Z
        DTEND:20300115T110000Z
        BEGIN:VALARM
        ACTION:EMAIL
        TRIGGER:-PT15M
        SUMMARY:Your meeting starts soon
        DESCRIPTION:Reminder
        ATTENDEE:mailto:host@example.com
        END:VALARM
        """)

      assert event.summary == nil
      assert event.attendees == []
    end

    # A repeating alarm states its interval as DURATION (RFC 5545 §3.6.6);
    # read as the event's, it set the event's length.
    test "an alarm's DURATION is not the length of an event with no DTEND" do
      event =
        parsed("""
        DTSTART:20300115T100000Z
        DURATION:PT2H
        BEGIN:VALARM
        ACTION:DISPLAY
        TRIGGER:-PT15M
        DURATION:PT5M
        REPEAT:2
        DESCRIPTION:Reminder
        END:VALARM
        """)

      assert event.end_time == ~U[2030-01-15 12:00:00Z]
    end

    test "an alarm's DURATION does not stand in for an event that has none" do
      event =
        parsed("""
        DTSTART:20300115T100000Z
        BEGIN:VALARM
        ACTION:DISPLAY
        TRIGGER:-PT15M
        DURATION:PT5M
        REPEAT:2
        DESCRIPTION:Reminder
        END:VALARM
        """)

      assert event.end_time == event.start_time
    end
  end

  describe "cached reminders" do
    test "each lead time before the start becomes a reminder" do
      assert reminders_for(alarm("TRIGGER:-P1D") <> alarm("TRIGGER;RELATED=START:-PT1H30M")) == [
               %{method: :popup, minutes_before: 1440},
               %{method: :popup, minutes_before: 90}
             ]
    end

    test "a week, a lowercase trigger and one at the start are read in full" do
      assert reminders_for(
               alarm("TRIGGER:-P1W") <> alarm("TRIGGER:-pt10m") <> alarm("TRIGGER:PT0S")
             ) ==
               [
                 %{method: :popup, minutes_before: 10_080},
                 %{method: :popup, minutes_before: 10},
                 %{method: :popup, minutes_before: 0}
               ]
    end

    test "an email alarm is an email reminder" do
      assert reminders_for(alarm("TRIGGER:-PT30M", "EMAIL")) == [
               %{method: :email, minutes_before: 30}
             ]
    end

    test "alarms that are not a lead time before the start are left out" do
      alarms =
        alarm("TRIGGER:PT15M") <>
          alarm("TRIGGER;RELATED=END:-PT5M") <>
          alarm("TRIGGER;VALUE=DATE-TIME:20300115T090000Z") <>
          alarm("TRIGGER:soon") <>
          alarm("TRIGGER:-PT20M")

      assert reminders_for(alarms) == [%{method: :popup, minutes_before: 20}]
    end

    test "an event without alarms has no reminders" do
      assert reminders_for("") == []
    end
  end
end
