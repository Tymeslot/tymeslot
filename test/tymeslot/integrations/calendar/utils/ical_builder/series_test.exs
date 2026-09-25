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

  describe "put_override/4 on a slot with no override yet" do
    defp put!(document, key, changes, timezone) do
      assert {:ok, result} = Series.put_override(document, key, changes, timezone)
      result
    end

    # The VEVENT blocks of a document, each as its unfolded lines.
    defp vevents(document) do
      document
      |> lines()
      |> Enum.chunk_while(
        nil,
        fn
          "BEGIN:VEVENT", nil -> {:cont, ["BEGIN:VEVENT"]}
          "END:VEVENT", acc when is_list(acc) -> {:cont, Enum.reverse(["END:VEVENT" | acc]), nil}
          line, acc when is_list(acc) -> {:cont, [line | acc]}
          _line, nil -> {:cont, nil}
        end,
        fn _unterminated -> {:cont, nil} end
      )
    end

    defp override_in(document, recurrence_id),
      do: Enum.find(vevents(document), &(recurrence_id in &1))

    @berlin_changes %{
      summary: "Weekly sync, afternoon",
      # 11 May 2026 is summer time in Berlin (UTC+2): 14:00 local.
      start_time: ~U[2026-05-11 12:00:00Z],
      end_time: ~U[2026-05-11 12:45:00Z]
    }

    test "a zoned series gains an override in the master's zone" do
      document =
        berlin_series("""
        LOCATION:Room 4
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:jane@example.com
        EXDATE;TZID=Europe/Berlin:20260518T100000
        RDATE;TZID=Europe/Berlin:20260606T100000
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        TRIGGER:-PT15M
        END:VALARM
        """)

      result = put!(document, "20260511T100000", @berlin_changes, "Europe/Berlin")
      override = override_in(result, "RECURRENCE-ID;TZID=Europe/Berlin:20260511T100000")

      assert "DTSTART;TZID=Europe/Berlin:20260511T140000" in override
      assert "DTEND;TZID=Europe/Berlin:20260511T144500" in override
      assert "SUMMARY:Weekly sync\\, afternoon" in override

      # What the change does not name is the master's, recurrence set aside.
      assert "UID:weekly-sync@example.com" in override
      assert "LOCATION:Room 4" in override
      assert "ATTENDEE;PARTSTAT=ACCEPTED:mailto:jane@example.com" in override

      assert ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT15M"] --
               override == []

      assert Enum.filter(override, &String.starts_with?(&1, ["RRULE", "RDATE", "EXDATE"])) == []
      # The payload's end replaces the master's DURATION rather than joining it.
      refute Enum.any?(override, &String.starts_with?(&1, "DURATION"))
      refute "DTSTAMP:20260401T090000Z" in override
      assert Enum.count(override, &String.starts_with?(&1, "DTSTAMP:")) == 1
    end

    test "the master and every other line of the document are left byte for byte" do
      document =
        LineFolder.fold_lines(
          calendar(
            @vtimezone <>
              master(
                "DTSTART;TZID=Europe/Berlin:20260504T100000",
                "DESCRIPTION:" <>
                  String.duplicate("Long enough to be folded on the wire. ", 4) <> "\n"
              ) <>
              override("RECURRENCE-ID;TZID=Europe/Berlin:20260518T100000", "Kept")
          )
        )

      result = put!(document, "20260511T100000", @berlin_changes, "Europe/Berlin")

      assert [_new_override] = vevents(result) -- vevents(document)
      assert vevents(document) -- vevents(result) == []
      # The untouched blocks come back as the same bytes, folding included.
      assert String.starts_with?(result, String.replace(document, ~r/END:VCALENDAR\r\n$/, ""))
    end

    test "a UTC series gains a UTC override" do
      document = calendar(master("DTSTART:20260504T080000Z"))

      result =
        put!(
          document,
          "20260511T080000",
          %{start_time: ~U[2026-05-11 13:00:00Z], end_time: ~U[2026-05-11 13:30:00Z]},
          nil
        )

      override = override_in(result, "RECURRENCE-ID:20260511T080000Z")
      assert "DTSTART:20260511T130000Z" in override
      assert "DTEND:20260511T133000Z" in override
    end

    test "an all-day series gains a date override" do
      document = calendar(master("DTSTART;VALUE=DATE:20260504"))

      result =
        put!(
          document,
          "20260511",
          %{summary: "Offsite", start_time: ~D[2026-05-12], end_time: ~D[2026-05-13]},
          nil
        )

      override = override_in(result, "RECURRENCE-ID;VALUE=DATE:20260511")
      assert "DTSTART;VALUE=DATE:20260512" in override
      assert "DTEND;VALUE=DATE:20260513" in override
      assert "SUMMARY:Offsite" in override
    end

    test "turning one occurrence of a timed series all-day is refused" do
      document = berlin_series()

      assert Series.put_override(
               document,
               "20260511T100000",
               %{start_time: ~D[2026-05-11], end_time: ~D[2026-05-12]},
               "Europe/Berlin"
             ) == {:error, :value_type_change}
    end

    test "a new override without its timing is refused" do
      assert Series.put_override(
               berlin_series(),
               "20260511T100000",
               %{summary: "X"},
               "Europe/Berlin"
             ) ==
               {:error, :missing_timing}
    end
  end

  describe "put_override/4 on a slot that already has an override" do
    test "the override is edited in place and keeps what the change does not name" do
      existing = """
      BEGIN:VEVENT
      UID:weekly-sync@example.com
      DTSTAMP:20260401T090000Z
      RECURRENCE-ID;TZID=Europe/Berlin:20260511T100000
      DTSTART;TZID=Europe/Berlin:20260511T150000
      DURATION:PT30M
      SUMMARY:Weekly sync, moved
      CATEGORIES:Moved
      X-MOZ-GENERATION:7
      END:VEVENT
      """

      document =
        calendar(
          @vtimezone <>
            master("DTSTART;TZID=Europe/Berlin:20260504T100000") <>
            existing <>
            override("RECURRENCE-ID;TZID=Europe/Berlin:20260518T100000", "Other")
        )

      result = put!(document, "20260511T100000", %{summary: "Renamed"}, "Europe/Berlin")

      assert length(vevents(result)) == 3
      edited = override_in(result, "RECURRENCE-ID;TZID=Europe/Berlin:20260511T100000")

      assert "SUMMARY:Renamed" in edited
      assert "DTSTART;TZID=Europe/Berlin:20260511T150000" in edited
      assert "DURATION:PT30M" in edited
      assert "CATEGORIES:Moved" in edited
      assert "X-MOZ-GENERATION:7" in edited

      untouched = vevents(document) -- [override_in(document, "SUMMARY:Weekly sync, moved")]
      assert untouched -- vevents(result) == []
    end

    test "an override named by a UTC instant is found in the series' zone" do
      document =
        calendar(
          @vtimezone <>
            master("DTSTART;TZID=Europe/Berlin:20260504T100000") <>
            override("RECURRENCE-ID:20260511T080000Z", "Moved")
        )

      result = put!(document, "20260511T100000", %{summary: "Renamed"}, "Europe/Berlin")

      assert length(vevents(result)) == 2
      assert "SUMMARY:Renamed" in override_in(result, "RECURRENCE-ID:20260511T080000Z")
    end
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

    defp normalised(document) do
      assert {:ok, raws} = EventProcessor.parse_ical_events(document)
      assert {:ok, events} = ICalNormaliser.normalise_events(raws, @context, :caldav)
      Map.new(events, &{&1.uid, &1})
    end

    defp berlin_instant(%Date{} = date, %Time{} = time),
      do: date |> DateTime.new!(time, "Europe/Berlin") |> DateTime.shift_zone!("Etc/UTC")

    test "a zoned series shows the edited summer occurrence at its new time under its uid" do
      {winter, summer} = winter_and_summer_mondays()
      document = berlin_series_from("DTSTART;TZID=Europe/Berlin:#{stamp(winter)}T100000")
      uid = &"weekly-sync@example.com_#{stamp(&1)}T100000"
      new_start = berlin_instant(summer, ~T[14:00:00])

      changes = %{
        summary: "Afternoon",
        start_time: new_start,
        end_time: DateTime.add(new_start, 45, :minute)
      }

      before = normalised(document)

      after_edit =
        normalised(put!(document, "#{stamp(summer)}T100000", changes, "Europe/Berlin"))

      assert Enum.sort(Map.keys(after_edit)) == Enum.sort(Map.keys(before))

      edited = after_edit[uid.(summer)]
      assert edited.summary == "Afternoon"
      assert DateTime.compare(edited.start_at, new_start) == :eq
      assert DateTime.compare(edited.end_at, DateTime.add(new_start, 45, :minute)) == :eq

      for neighbour <- [Date.add(summer, -7), Date.add(summer, 7), winter] do
        assert after_edit[uid.(neighbour)].summary == "Weekly sync"

        assert DateTime.compare(
                 after_edit[uid.(neighbour)].start_at,
                 before[uid.(neighbour)].start_at
               ) == :eq
      end
    end

    test "a zoned series keeps a winter occurrence edited from summer on its wall clock" do
      {_winter, summer} = winter_and_summer_mondays()
      # The series starts in summer, so the edited winter occurrence is on the
      # other side of the DST change from the master's DTSTART.
      document = berlin_series_from("DTSTART;TZID=Europe/Berlin:#{stamp(summer)}T100000")
      target = Date.add(summer, 26 * 7)
      new_start = berlin_instant(target, ~T[09:00:00])
      uid = "weekly-sync@example.com_#{stamp(target)}T100000"

      after_edit =
        normalised(
          put!(
            document,
            "#{stamp(target)}T100000",
            %{start_time: new_start, end_time: DateTime.add(new_start, 30, :minute)},
            "Europe/Berlin"
          )
        )

      assert DateTime.compare(after_edit[uid].start_at, new_start) == :eq
    end

    test "an all-day series shows the edited day under its uid" do
      first = Date.add(Date.utc_today(), 7)
      edited_day = Date.add(first, 7)
      document = calendar(master("DTSTART;VALUE=DATE:#{stamp(first)}"))
      uid = &"weekly-sync@example.com_#{stamp(&1)}"

      after_edit =
        normalised(
          put!(
            document,
            stamp(edited_day),
            %{
              summary: "Moved",
              start_time: Date.add(edited_day, 1),
              end_time: Date.add(edited_day, 2)
            },
            nil
          )
        )

      assert after_edit[uid.(edited_day)].summary == "Moved"
      assert after_edit[uid.(first)].summary == "Weekly sync"
      assert after_edit[uid.(Date.add(edited_day, 7))].summary == "Weekly sync"
    end

    defp berlin_series_from(dtstart), do: calendar(@vtimezone <> master(dtstart))
  end
end
