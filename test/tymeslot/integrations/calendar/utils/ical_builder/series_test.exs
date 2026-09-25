defmodule Tymeslot.Integrations.Calendar.ICalBuilder.SeriesTest do
  @moduledoc """
  Removing one occurrence from a recurring event stored as a single CalDAV
  resource: the master `VEVENT` gains an `EXDATE` naming the slot, and any
  override `VEVENT` standing in that slot goes.

  The `EXDATE` has to name the slot the way the master's `DTSTART` names the
  series (RFC 5545 §3.8.5.1), so the round-trip tests at the bottom feed the
  result back through the parser and normaliser the sync uses: an `EXDATE` the
  sync misreads would leave the occurrence on the grid however well formed the
  document looks.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series
  alias Tymeslot.Integrations.Calendar.ICalNormaliser

  @context %{
    calendar_integration_id: 1,
    provider_calendar_id: "/cal/primary",
    synced_at: ~U[2026-09-01 00:00:00Z]
  }

  @vtimezone """
  BEGIN:VTIMEZONE
  TZID:Europe/Berlin
  BEGIN:DAYLIGHT
  TZOFFSETFROM:+0100
  TZOFFSETTO:+0200
  TZNAME:CEST
  DTSTART:19700329T020000
  RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
  END:DAYLIGHT
  BEGIN:STANDARD
  TZOFFSETFROM:+0200
  TZOFFSETTO:+0100
  TZNAME:CET
  DTSTART:19701025T030000
  RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
  END:STANDARD
  END:VTIMEZONE
  """

  defp calendar(body) do
    document = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Example Corp//Calendar 1.0//EN
    #{body}END:VCALENDAR
    """

    String.replace(document, ~r/\r?\n/, "\r\n")
  end

  defp master(dtstart, extra \\ "") do
    """
    BEGIN:VEVENT
    UID:weekly-sync@example.com
    DTSTAMP:20260401T090000Z
    #{dtstart}
    DURATION:PT30M
    RRULE:FREQ=WEEKLY
    SUMMARY:Weekly sync
    #{extra}END:VEVENT
    """
  end

  defp override(recurrence_id, summary \\ "Weekly sync, moved") do
    """
    BEGIN:VEVENT
    UID:weekly-sync@example.com
    DTSTAMP:20260401T090000Z
    #{recurrence_id}
    DTSTART;TZID=Europe/Berlin:20260101T150000
    DURATION:PT30M
    SUMMARY:#{summary}
    END:VEVENT
    """
  end

  defp berlin_series(extra \\ ""),
    do: calendar(@vtimezone <> master("DTSTART;TZID=Europe/Berlin:20260504T100000", extra))

  defp lines(document), do: Enum.reject(LineFolder.unfold_lines(document), &(&1 == ""))

  defp exdates(document),
    do: document |> lines() |> Enum.filter(&String.starts_with?(&1, "EXDATE"))

  defp exclude!(document, key, timezone) do
    assert {:ok, result} = Series.exclude_occurrence(document, key, timezone)
    result
  end

  describe "exclude_occurrence/3 writes the EXDATE the way DTSTART names the series" do
    test "a zoned series gets an EXDATE in the same zone" do
      document = berlin_series()
      result = exclude!(document, "20260511T100000", "Europe/Berlin")

      assert exdates(result) == ["EXDATE;TZID=Europe/Berlin:20260511T100000"]

      # The EXDATE is the only change, and it lands after the RRULE.
      assert List.delete(lines(result), "EXDATE;TZID=Europe/Berlin:20260511T100000") ==
               lines(document)

      rrule_at = Enum.find_index(lines(result), &(&1 == "RRULE:FREQ=WEEKLY"))
      assert Enum.at(lines(result), rrule_at + 1) == "EXDATE;TZID=Europe/Berlin:20260511T100000"
    end

    test "a UTC series gets a UTC EXDATE" do
      document = calendar(master("DTSTART:20260504T080000Z"))
      result = exclude!(document, "20260511T080000", nil)

      assert exdates(result) == ["EXDATE:20260511T080000Z"]
    end

    test "a floating series gets a floating EXDATE" do
      document = calendar(master("DTSTART:20260504T100000"))
      result = exclude!(document, "20260511T100000", nil)

      assert exdates(result) == ["EXDATE:20260511T100000"]
    end

    test "an all-day series gets a date EXDATE" do
      document = calendar(master("DTSTART;VALUE=DATE:20260504"))
      result = exclude!(document, "20260511", nil)

      assert exdates(result) == ["EXDATE;VALUE=DATE:20260511"]
    end

    test "existing EXDATEs are kept and the new one follows them, once" do
      document =
        berlin_series("""
        EXDATE;TZID=Europe/Berlin:20260518T100000
        EXDATE;TZID=Europe/Berlin:20260525T100000,20260601T100000
        """)

      once = exclude!(document, "20260511T100000", "Europe/Berlin")
      twice = exclude!(once, "20260511T100000", "Europe/Berlin")

      assert exdates(once) == [
               "EXDATE;TZID=Europe/Berlin:20260518T100000",
               "EXDATE;TZID=Europe/Berlin:20260525T100000,20260601T100000",
               "EXDATE;TZID=Europe/Berlin:20260511T100000"
             ]

      assert lines(twice) == lines(once)
    end

    test "a slot already listed inside a multi-value EXDATE is not added again" do
      document = berlin_series("EXDATE;TZID=Europe/Berlin:20260511T100000,20260518T100000\n")

      assert lines(exclude!(document, "20260511T100000", "Europe/Berlin")) == lines(document)
    end
  end

  describe "exclude_occurrence/3 drops the override standing in the slot" do
    test "the override for the slot goes and another override stays" do
      document =
        calendar(
          @vtimezone <>
            master("DTSTART;TZID=Europe/Berlin:20260504T100000") <>
            override("RECURRENCE-ID;TZID=Europe/Berlin:20260511T100000", "Gone") <>
            override("RECURRENCE-ID;TZID=Europe/Berlin:20260518T100000", "Kept")
        )

      result = lines(exclude!(document, "20260511T100000", "Europe/Berlin"))

      refute "SUMMARY:Gone" in result
      refute "RECURRENCE-ID;TZID=Europe/Berlin:20260511T100000" in result
      assert "SUMMARY:Kept" in result
      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260518T100000" in result
      assert "EXDATE;TZID=Europe/Berlin:20260511T100000" in result
    end

    test "an override written as a UTC instant is read in the series' zone" do
      document =
        calendar(
          @vtimezone <>
            master("DTSTART;TZID=Europe/Berlin:20260504T100000") <>
            override("RECURRENCE-ID:20260511T080000Z", "Gone")
        )

      result = lines(exclude!(document, "20260511T100000", "Europe/Berlin"))

      refute "SUMMARY:Gone" in result
      assert Enum.count(result, &(&1 == "BEGIN:VEVENT")) == 1
    end

    test "a resource holding only that override is left empty" do
      document =
        calendar(@vtimezone <> override("RECURRENCE-ID;TZID=Europe/Berlin:20260511T100000"))

      assert Series.exclude_occurrence(document, "20260511T100000", "Europe/Berlin") == :empty
    end

    test "a resource holding only another override is left alone" do
      document =
        calendar(@vtimezone <> override("RECURRENCE-ID;TZID=Europe/Berlin:20260518T100000"))

      assert lines(exclude!(document, "20260511T100000", "Europe/Berlin")) == lines(document)
    end
  end

  test "everything else in the document survives byte for byte" do
    long_description =
      "DESCRIPTION:" <> String.duplicate("A line long enough to be folded on the wire. ", 4)

    series =
      berlin_series("""
      CATEGORIES:Work,Planning
      X-MOZ-GENERATION:4
      X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC
      ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN="Doe, Jane":mailto:jane@example.com
      #{long_description}
      BEGIN:VALARM
      ACTION:DISPLAY
      DESCRIPTION:Reminder
      TRIGGER:-PT15M
      END:VALARM
      """)

    document = LineFolder.fold_lines(series)

    result = exclude!(document, "20260511T100000", "Europe/Berlin")

    assert List.delete(lines(result), "EXDATE;TZID=Europe/Berlin:20260511T100000") ==
             lines(document)

    assert String.ends_with?(result, "END:VCALENDAR\r\n")
    assert Enum.all?(String.split(result, "\r\n"), &(byte_size(&1) <= 75))
  end

  describe "round trip through the sync's parser and normaliser" do
    defp occurrence_uids(document) do
      assert {:ok, raws} = EventProcessor.parse_ical_events(document)
      assert {:ok, events} = ICalNormaliser.normalise_events(raws, @context, :caldav)
      events |> Enum.map(& &1.uid) |> MapSet.new()
    end

    defp stamp(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")

    # The Monday of the week holding the next 15 July, and the Monday 26 weeks
    # earlier: summer and winter in Berlin, both inside the sync's window
    # whatever the date the suite runs on.
    defp winter_and_summer_mondays do
      today = Date.utc_today()
      july = Date.new!(today.year, 7, 15)
      july = if Date.compare(july, today) == :lt, do: Date.new!(today.year + 1, 7, 15), else: july
      summer = Date.beginning_of_week(july)
      {Date.add(summer, -26 * 7), summer}
    end

    test "a zoned series loses the excluded summer occurrence across the DST change" do
      {winter, summer} = winter_and_summer_mondays()
      document = berlin_series_from("DTSTART;TZID=Europe/Berlin:#{stamp(winter)}T100000")
      key = "#{stamp(summer)}T100000"
      uid = &"weekly-sync@example.com_#{stamp(&1)}T100000"

      before = occurrence_uids(document)
      assert uid.(summer) in before

      after_exclusion = occurrence_uids(exclude!(document, key, "Europe/Berlin"))

      refute uid.(summer) in after_exclusion
      assert uid.(Date.add(summer, -7)) in after_exclusion
      assert uid.(Date.add(summer, 7)) in after_exclusion
      assert MapSet.difference(before, after_exclusion) == MapSet.new([uid.(summer)])
    end

    test "an all-day series loses the excluded day" do
      first = Date.add(Date.utc_today(), 7)
      excluded = Date.add(first, 7)
      document = calendar(master("DTSTART;VALUE=DATE:#{stamp(first)}"))
      uid = &"weekly-sync@example.com_#{stamp(&1)}"

      before = occurrence_uids(document)
      assert uid.(excluded) in before

      after_exclusion = occurrence_uids(exclude!(document, stamp(excluded), nil))

      refute uid.(excluded) in after_exclusion
      assert uid.(first) in after_exclusion
      assert uid.(Date.add(excluded, 7)) in after_exclusion
      assert MapSet.difference(before, after_exclusion) == MapSet.new([uid.(excluded)])
    end

    test "a UTC series loses the excluded occurrence" do
      first = Date.add(Date.utc_today(), 7)
      excluded = Date.add(first, 7)
      document = calendar(master("DTSTART:#{stamp(first)}T080000Z"))
      uid = &"weekly-sync@example.com_#{stamp(&1)}T080000"

      before = occurrence_uids(document)
      assert uid.(excluded) in before

      after_exclusion = occurrence_uids(exclude!(document, "#{stamp(excluded)}T080000", nil))

      assert MapSet.difference(before, after_exclusion) == MapSet.new([uid.(excluded)])
    end

    defp berlin_series_from(dtstart), do: calendar(@vtimezone <> master(dtstart))
  end
end
