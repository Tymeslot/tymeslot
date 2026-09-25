defmodule Tymeslot.Integrations.Calendar.CalDAV.RecurrenceOverrideTest do
  @moduledoc """
  A recurring CalDAV event is one resource holding several `VEVENT`s: the
  master, plus one per occurrence the organiser has edited on its own, each
  carrying a `RECURRENCE-ID` and no `RRULE`.

  Both sync paths used to keep only the first of them, and RFC 5545 fixes no
  order between them, so either an edited occurrence was dropped or it became
  the only cached row for the whole series.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor

  describe "a recurring event whose occurrences have been edited on their own" do
    @override_context %{
      calendar_integration_id: 42,
      provider_calendar_id: "default",
      synced_at: ~U[2026-04-08 12:00:00Z]
    }

    # One CalDAV resource, three VEVENTs: the master and two occurrences edited
    # on their own. Everything after the first used to be discarded before the
    # normaliser ever saw it, and RFC 5545 fixes no order between them.
    defp series_with_overrides(first_occurrence) do
      """
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Test//Test//EN
      BEGIN:VEVENT
      UID:series-with-overrides@example.com
      DTSTART:#{ical_date(first_occurrence)}T090000Z
      DTEND:#{ical_date(first_occurrence)}T093000Z
      RRULE:FREQ=DAILY;COUNT=3
      SUMMARY:Daily Standup
      END:VEVENT
      BEGIN:VEVENT
      UID:series-with-overrides@example.com
      RECURRENCE-ID:#{ical_date(Date.add(first_occurrence, 1))}T090000Z
      DTSTART:#{ical_date(Date.add(first_occurrence, 1))}T140000Z
      DTEND:#{ical_date(Date.add(first_occurrence, 1))}T143000Z
      SUMMARY:Standup, moved to the afternoon
      END:VEVENT
      END:VCALENDAR
      """
    end

    test "keeps every VEVENT in the resource" do
      first = Date.add(Date.utc_today(), 7)

      assert {:ok, [master, override]} =
               EventProcessor.parse_ical_events(series_with_overrides(first))

      assert master.recurrence_rule == "FREQ=DAILY;COUNT=3"
      assert master.recurrence_id == nil
      assert override.recurrence_id == ical_date(Date.add(first, 1)) <> "T090000Z"
      assert override.recurrence_rule == nil
    end

    test "the override replaces its occurrence and the rest of the series survives" do
      first = Date.add(Date.utc_today(), 7)

      assert {:ok, raws} = EventProcessor.parse_ical_events(series_with_overrides(first))
      assert {:ok, events} = EventProcessor.normalise_events(raws, @override_context)

      # Three occurrences, not four: the override stands in place of the
      # occurrence it names rather than appearing beside it.
      assert length(events) == 3

      summaries = events |> Enum.map(& &1.summary) |> Enum.sort()
      assert summaries == ["Daily Standup", "Daily Standup", "Standup, moved to the afternoon"]

      moved = Enum.find(events, &(&1.summary == "Standup, moved to the afternoon"))

      # It carries its own new time, and the identity of the slot it replaced,
      # so the cache updates that occurrence's row rather than growing a second.
      assert DateTime.to_time(moved.start_at) == ~T[14:00:00]

      assert moved.uid ==
               "series-with-overrides@example.com_#{ical_date(Date.add(first, 1))}T090000"

      # Nothing is left sitting at the original 09:00 slot on that day.
      refute Enum.any?(events, fn event ->
               DateTime.to_date(event.start_at) == Date.add(first, 1) and
                 DateTime.to_time(event.start_at) == ~T[09:00:00]
             end)
    end

    # The order two VEVENTs appear in is the server's choice, so the result
    # must not depend on it.
    test "the outcome does not depend on which VEVENT the server listed first" do
      first = Date.add(Date.utc_today(), 7)

      assert {:ok, [master, override]} =
               EventProcessor.parse_ical_events(series_with_overrides(first))

      assert {:ok, forwards} =
               EventProcessor.normalise_events([master, override], @override_context)

      assert {:ok, backwards} =
               EventProcessor.normalise_events([override, master], @override_context)

      assert Enum.sort(Enum.map(forwards, & &1.uid)) ==
               Enum.sort(Enum.map(backwards, & &1.uid))

      assert length(backwards) == 3
    end
  end

  defp ical_date(date), do: Calendar.strftime(date, "%Y%m%d")
end
