defmodule Tymeslot.Integrations.Calendar.ICalNormaliserOccurrenceUidTest do
  @moduledoc """
  The UID suffix each expanded occurrence of a recurring event is given.

  The suffix is local wall-clock time in the event's own zone, and must not be
  labelled `Z`. It is also the occurrence's stable identity: cache rows are
  keyed on `(calendar_integration_id, uid)`, so a suffix that moved across a
  DST boundary would write a second row per occurrence instead of updating the
  one already there.
  """

  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.ICalNormaliser

  @context %{
    calendar_integration_id: 1,
    provider_calendar_id: "/cal/primary",
    synced_at: ~U[2026-09-01 00:00:00Z]
  }

  # A fortnightly Europe/Stockholm event spanning the October DST boundary,
  # the shape this was observed on in production.
  defp fortnightly_stockholm do
    %{
      uid: "D2B2CBB0-F8B5-4EA6-9B43-287EF45F4EC2",
      summary: "Standup",
      timezone: "Europe/Stockholm",
      dtstart: DateTime.new!(~D[2026-09-02], ~T[10:00:00], "Europe/Stockholm"),
      dtend: DateTime.new!(~D[2026-09-02], ~T[10:30:00], "Europe/Stockholm"),
      rrule: "FREQ=WEEKLY;INTERVAL=2"
    }
  end

  defp occurrence_uids do
    {:ok, events} = ICalNormaliser.normalise_events([fortnightly_stockholm()], @context, :caldav)

    events
    |> Enum.map(& &1.uid)
    |> Enum.filter(&String.contains?(&1, "_"))
  end

  test "no occurrence UID carries a UTC marker it does not mean" do
    uids = occurrence_uids()

    assert uids != []
    assert Enum.reject(uids, &(not String.ends_with?(&1, "Z"))) == []
  end

  test "the suffix is the event's own wall-clock time" do
    uids = occurrence_uids()

    assert uids != []

    suffixes = uids |> Enum.map(&(&1 |> String.split("_") |> List.last())) |> Enum.uniq()

    # Every occurrence is at 10:00 Stockholm local, on both sides of the
    # October DST transition, so every suffix carries the same wall time.
    assert Enum.reject(suffixes, &String.ends_with?(&1, "T100000")) == []
  end

  test "the suffix is stable across a DST boundary, so identity does not fork" do
    {:ok, events} = ICalNormaliser.normalise_events([fortnightly_stockholm()], @context, :caldav)

    occurrences =
      events
      |> Enum.filter(&String.contains?(&1.uid, "_"))
      |> Enum.map(&{&1.uid, &1.start_at})

    assert occurrences != []

    # Summer (CEST, +02:00) and winter (CET, +01:00) occurrences both exist:
    # the stored instants genuinely differ by an hour of offset, which is what
    # makes the constant wall-clock suffix the load-bearing part.
    offsets =
      occurrences
      |> Enum.map(fn {_uid, start_at} ->
        start_at
        |> DateTime.shift_zone!("Europe/Stockholm")
        |> then(&(&1.utc_offset + &1.std_offset))
      end)
      |> Enum.uniq()

    assert 7200 in offsets
    assert 3600 in offsets

    # One row per occurrence: no UID is issued twice.
    uids = Enum.map(occurrences, &elem(&1, 0))
    assert length(Enum.uniq(uids)) == length(uids)
  end

  test "a non-recurring event keeps its UID untouched" do
    single = Map.drop(fortnightly_stockholm(), [:rrule])

    {:ok, [event]} = ICalNormaliser.normalise_events([single], @context, :caldav)

    assert event.uid == "D2B2CBB0-F8B5-4EA6-9B43-287EF45F4EC2"
  end

  describe "the zone a row records" do
    # The parser hands every DTSTART over in UTC; the row has to record the
    # zone the event was written in, or a later edit of it is placed in UTC.
    defp normalised(vevents) do
      document =
        String.replace(
          "BEGIN:VCALENDAR\nVERSION:2.0\n" <> vevents <> "END:VCALENDAR\n",
          "\n",
          "\r\n"
        )

      {:ok, raws} = EventProcessor.parse_ical_events(document)
      {:ok, events} = ICalNormaliser.normalise_events(raws, @context, :caldav)
      Map.new(events, &{&1.uid, &1})
    end

    test "a one-off event keeps its own zone, and its instant" do
      events =
        normalised("""
        BEGIN:VEVENT
        UID:one-off
        DTSTAMP:20260901T090000Z
        DTSTART;TZID=Europe/Berlin:20260915T090000
        DTEND;TZID=Europe/Berlin:20260915T100000
        SUMMARY:One-off
        END:VEVENT
        """)

      assert %{timezone: "Europe/Berlin", start_at: ~U[2026-09-15 07:00:00Z]} = events["one-off"]
    end

    test "an occurrence override records its series' zone like every sibling" do
      events =
        normalised("""
        BEGIN:VEVENT
        UID:weekly
        DTSTAMP:20260901T090000Z
        DTSTART;TZID=Europe/Berlin:20260908T090000
        DTEND;TZID=Europe/Berlin:20260908T091500
        RRULE:FREQ=WEEKLY;COUNT=3
        SUMMARY:Weekly
        END:VEVENT
        BEGIN:VEVENT
        UID:weekly
        DTSTAMP:20260901T090000Z
        RECURRENCE-ID;TZID=Europe/Berlin:20260915T090000
        DTSTART;TZID=Europe/Berlin:20260915T110000
        DTEND;TZID=Europe/Berlin:20260915T111500
        SUMMARY:Weekly, moved
        END:VEVENT
        """)

      assert %{timezone: "Europe/Berlin", start_at: ~U[2026-09-15 09:00:00Z]} =
               events["weekly_20260915T090000"]

      assert events["weekly_20260922T090000"].timezone == "Europe/Berlin"
    end
  end

  describe "occurrence_key/2" do
    test "a zoned RECURRENCE-ID is taken as written" do
      assert ICalNormaliser.occurrence_key("20260511T100000", "Europe/Berlin") ==
               "20260511T100000"
    end

    test "a floating RECURRENCE-ID is taken as written" do
      assert ICalNormaliser.occurrence_key("20260511T100000", nil) == "20260511T100000"
    end

    test "an all-day RECURRENCE-ID is its date" do
      assert ICalNormaliser.occurrence_key("20260511", nil) == "20260511"
    end

    test "a UTC RECURRENCE-ID is read in the series' zone" do
      assert ICalNormaliser.occurrence_key("20260511T080000Z", "Europe/Berlin") ==
               "20260511T100000"

      assert ICalNormaliser.occurrence_key("20260511T080000Z", nil) == "20260511T080000"
    end

    test "an unreadable value has no key" do
      assert ICalNormaliser.occurrence_key("next Tuesday", "Europe/Berlin") == nil
      assert ICalNormaliser.occurrence_key(nil, "Europe/Berlin") == nil
    end
  end
end
