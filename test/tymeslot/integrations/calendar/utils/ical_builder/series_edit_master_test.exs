defmodule Tymeslot.Integrations.Calendar.ICalBuilder.SeriesEditMasterTest do
  @moduledoc """
  Editing every occurrence of a recurring event stored as one CalDAV
  resource, from the edit of one of them (`Series.edit_master/5`).

  Moving the series moves every line that names one of its slots by the same
  amount, each in its own form, or the exceptions and overrides stop naming
  the occurrences they were written for. The round trips at the bottom read
  the result back through the sync's parser and normaliser, which is where a
  slot left behind shows: as an excluded occurrence back on the grid, or an
  occurrence shown twice.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  import Tymeslot.Test.ICalSeriesFixtures

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series

  @vtimezone vtimezone()

  # A weekly Berlin series from Monday 5 January 2026 (winter, UTC+1), with a
  # winter and a summer occurrence excluded and the 6 July one (summer, UTC+2)
  # moved to the afternoon.
  @berlin_master """
  BEGIN:VEVENT
  UID:weekly-sync@example.com
  DTSTAMP:20260101T090000Z
  DTSTART;TZID=Europe/Berlin:20260105T100000
  DTEND;TZID=Europe/Berlin:20260105T103000
  RRULE:FREQ=WEEKLY
  EXDATE;TZID=Europe/Berlin:20260112T100000,20260713T100000
  SUMMARY:Weekly sync
  END:VEVENT
  """

  @berlin_override """
  BEGIN:VEVENT
  UID:weekly-sync@example.com
  DTSTAMP:20260101T090000Z
  RECURRENCE-ID;TZID=Europe/Berlin:20260706T100000
  DTSTART;TZID=Europe/Berlin:20260706T150000
  DTEND;TZID=Europe/Berlin:20260706T153000
  SUMMARY:Moved to the afternoon
  END:VEVENT
  """

  defp berlin_document, do: calendar(@vtimezone <> @berlin_master <> @berlin_override)

  defp edit!(document, key, changes, timezone) do
    assert {:ok, result} = Series.edit_master(document, key, changes, timezone)
    result
  end

  defp master_of(document), do: document |> vevents() |> Enum.find(&(not recurrence_id?(&1)))
  defp overrides_of(document), do: document |> vevents() |> Enum.filter(&recurrence_id?/1)
  defp recurrence_id?(vevent), do: Enum.any?(vevent, &String.starts_with?(&1, "RECURRENCE-ID"))

  defp slot_lines(document),
    do: document |> lines() |> Enum.filter(&String.starts_with?(&1, ["EXDATE", "RECURRENCE-ID"]))

  describe "edit_master/4 moving a zoned series" do
    # 20 July 2026 is summer time (UTC+2): 10:00 moves to 11:00 in Berlin.
    @one_hour_later %{start_time: ~U[2026-07-20 09:00:00Z], end_time: ~U[2026-07-20 09:30:00Z]}

    test "moves the master's wall clock by the hour across the DST change" do
      master = master_of(edit!(berlin_document(), "20260720T100000", @one_hour_later, nil))

      assert "DTSTART;TZID=Europe/Berlin:20260105T110000" in master
      assert "DTEND;TZID=Europe/Berlin:20260105T113000" in master
    end

    test "moves every excluded slot by the same hour, in the master's zone" do
      result = edit!(berlin_document(), "20260720T100000", @one_hour_later, nil)

      assert "EXDATE;TZID=Europe/Berlin:20260112T110000,20260713T110000" in master_of(result)
    end

    test "moves an override's slot and its own timing by the same hour" do
      result = edit!(berlin_document(), "20260720T100000", @one_hour_later, nil)
      [override] = overrides_of(result)

      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260706T110000" in override
      assert "DTSTART;TZID=Europe/Berlin:20260706T160000" in override
      assert "DTEND;TZID=Europe/Berlin:20260706T163000" in override
      assert "SUMMARY:Moved to the afternoon" in override
    end

    test "leaves the time zone definition alone" do
      result = edit!(berlin_document(), "20260720T100000", @one_hour_later, nil)

      assert String.contains?(result, "DTSTART:19700329T020000")
      assert String.contains?(result, "DTSTART:19701025T030000")
    end

    test "moves from where an overridden occurrence shows, not from its slot" do
      # The 6 July occurrence shows at 15:00; dragging it to 16:00 is an hour.
      changes = %{start_time: ~U[2026-07-06 14:00:00Z], end_time: ~U[2026-07-06 14:30:00Z]}
      result = edit!(berlin_document(), "20260706T100000", changes, nil)

      assert "DTSTART;TZID=Europe/Berlin:20260105T110000" in master_of(result)
      assert "DTSTART;TZID=Europe/Berlin:20260706T160000" in hd(overrides_of(result))
    end
  end

  describe "edit_master/4 moving a UTC series" do
    test "moves every instant by the same amount" do
      document =
        calendar(
          master("DTSTART:20260504T080000Z", "EXDATE:20260511T080000Z\n") <>
            """
            BEGIN:VEVENT
            UID:weekly-sync@example.com
            RECURRENCE-ID:20260518T080000Z
            DTSTART:20260518T130000Z
            DURATION:PT30M
            END:VEVENT
            """
        )

      changes = %{start_time: ~U[2026-05-25 09:30:00Z], end_time: ~U[2026-05-25 10:00:00Z]}
      result = edit!(document, "20260525T080000", changes, nil)

      master = master_of(result)
      assert "DTSTART:20260504T093000Z" in master
      assert "EXDATE:20260511T093000Z" in master
      assert "DURATION:PT30M" in master

      [override] = overrides_of(result)
      assert "RECURRENCE-ID:20260518T093000Z" in override
      assert "DTSTART:20260518T143000Z" in override
    end
  end

  describe "edit_master/4 moving an all-day series" do
    @all_day """
    BEGIN:VEVENT
    UID:weekly-sync@example.com
    DTSTART;VALUE=DATE:20260504
    DTEND;VALUE=DATE:20260505
    RRULE:FREQ=WEEKLY
    EXDATE;VALUE=DATE:20260511
    SUMMARY:Offsite
    END:VEVENT
    BEGIN:VEVENT
    UID:weekly-sync@example.com
    RECURRENCE-ID;VALUE=DATE:20260518
    DTSTART;VALUE=DATE:20260519
    DTEND;VALUE=DATE:20260520
    SUMMARY:Offsite, a day late
    END:VEVENT
    """

    test "moves every date by whole days" do
      changes = %{start_time: ~D[2026-05-27], end_time: ~D[2026-05-28]}
      result = edit!(calendar(@all_day), "20260525", changes, nil)

      master = master_of(result)
      assert "DTSTART;VALUE=DATE:20260506" in master
      assert "DTEND;VALUE=DATE:20260507" in master
      assert "EXDATE;VALUE=DATE:20260513" in master

      [override] = overrides_of(result)
      assert "RECURRENCE-ID;VALUE=DATE:20260520" in override
      assert "DTSTART;VALUE=DATE:20260521" in override
    end

    test "refuses to move a date by part of a day" do
      # A date EXDATE in a timed series, as some clients write one.
      document =
        calendar(
          @vtimezone <>
            master("DTSTART;TZID=Europe/Berlin:20260504T100000", "EXDATE;VALUE=DATE:20260511\n")
        )

      changes = %{start_time: ~U[2026-05-18 09:00:00Z], end_time: ~U[2026-05-18 09:30:00Z]}

      assert Series.edit_master(document, "20260518T100000", changes, nil) ==
               {:error, :shift_not_whole_days}
    end

    test "refuses to turn the series timed" do
      changes = %{start_time: ~U[2026-05-25 09:00:00Z], end_time: ~U[2026-05-25 10:00:00Z]}

      assert Series.edit_master(calendar(@all_day), "20260525", changes, nil) ==
               {:error, :value_type_change}
    end
  end

  describe "edit_master/4 with plain fields" do
    test "writes them to the master and leaves every slot and override byte for byte" do
      document = berlin_document()

      # The occurrence's own timing, unchanged: 10:00 in Berlin in summer.
      changes = %{
        summary: "Renamed",
        location: "Room 5",
        start_time: ~U[2026-07-20 08:00:00Z],
        end_time: ~U[2026-07-20 08:30:00Z]
      }

      result = edit!(document, "20260720T100000", changes, nil)

      master = master_of(result)
      assert "SUMMARY:Renamed" in master
      assert "LOCATION:Room 5" in master
      assert "DTSTART;TZID=Europe/Berlin:20260105T100000" in master
      assert "DTEND;TZID=Europe/Berlin:20260105T103000" in master

      assert slot_lines(result) == slot_lines(document)
      assert overrides_of(result) == overrides_of(document)
    end

    test "without timing, nothing moves" do
      document = berlin_document()
      result = edit!(document, "20260720T100000", %{summary: "Renamed"}, nil)

      assert "DTSTART;TZID=Europe/Berlin:20260105T100000" in master_of(result)
      assert slot_lines(result) == slot_lines(document)
    end
  end

  describe "edit_master/4 changing the duration" do
    test "gives the master and the overrides that shared its duration the new one" do
      document =
        calendar(
          @vtimezone <>
            master("DTSTART;TZID=Europe/Berlin:20260504T100000") <>
            """
            BEGIN:VEVENT
            UID:weekly-sync@example.com
            RECURRENCE-ID;TZID=Europe/Berlin:20260511T100000
            DTSTART;TZID=Europe/Berlin:20260511T140000
            DURATION:PT30M
            END:VEVENT
            BEGIN:VEVENT
            UID:weekly-sync@example.com
            RECURRENCE-ID;TZID=Europe/Berlin:20260518T100000
            DTSTART;TZID=Europe/Berlin:20260518T140000
            DTEND;TZID=Europe/Berlin:20260518T150000
            END:VEVENT
            """
        )

      # 25 May, 10:00 to 10:45 in Berlin (UTC+2): same start, 15 minutes longer.
      changes = %{start_time: ~U[2026-05-25 08:00:00Z], end_time: ~U[2026-05-25 08:45:00Z]}
      result = edit!(document, "20260525T100000", changes, nil)

      master = master_of(result)
      assert "DTEND;TZID=Europe/Berlin:20260504T104500" in master
      refute Enum.any?(master, &String.starts_with?(&1, "DURATION"))

      [same_as_master, own_duration] = overrides_of(result)
      assert "DTEND;TZID=Europe/Berlin:20260511T144500" in same_as_master
      assert "DTEND;TZID=Europe/Berlin:20260518T150000" in own_duration
    end
  end

  describe "edit_master/4 changing the rule" do
    test "replaces the RRULE with its UNTIL in the series' zone and keeps the exceptions" do
      document = berlin_document()

      result =
        edit!(document, "20260720T100000", %{recurrence_rule: "FREQ=WEEKLY;UNTIL=20261231"}, nil)

      master = master_of(result)
      # The end of 31 December in Berlin (UTC+1), as an instant.
      assert "RRULE:FREQ=WEEKLY;UNTIL=20261231T225959Z" in master
      refute "RRULE:FREQ=WEEKLY" in master
      assert slot_lines(result) == slot_lines(document)
    end

    test "refuses to take the rule away" do
      assert Series.edit_master(
               berlin_document(),
               "20260720T100000",
               %{recurrence_rule: nil},
               nil
             ) ==
               {:error, :rule_removal}
    end
  end

  describe "edit_master/4 moving a series to another weekday" do
    # A Berlin series whose weekly rule is `rule`, from Monday 4 May 2026.
    defp weekly(rule),
      do:
        calendar(
          @vtimezone <>
            String.replace(
              master("DTSTART;TZID=Europe/Berlin:20260504T100000"),
              "RRULE:FREQ=WEEKLY",
              "RRULE:" <> rule
            )
        )

    # 25 May 2026 is a Monday, summer time in Berlin (UTC+2).
    defp moved_to(%Date{} = date, hour) do
      start =
        date
        |> DateTime.new!(Time.new!(hour, 0, 0), "Europe/Berlin")
        |> DateTime.shift_zone!("Etc/UTC")

      %{start_time: start, end_time: DateTime.add(start, 30, :minute)}
    end

    defp rule_after(rule, date, hour) do
      assert {:ok, moved} =
               Series.edit_master(weekly(rule), "20260525T100000", moved_to(date, hour), nil)

      moved |> master_of() |> Enum.find(&String.starts_with?(&1, "RRULE"))
    end

    test "a Monday series moved to Tuesday, an hour earlier, repeats on Tuesdays" do
      document =
        calendar(
          @vtimezone <>
            String.replace(
              master(
                "DTSTART;TZID=Europe/Berlin:20260504T100000",
                "EXDATE;TZID=Europe/Berlin:20260511T100000\n"
              ),
              "RRULE:FREQ=WEEKLY",
              "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10"
            ) <>
            """
            BEGIN:VEVENT
            UID:weekly-sync@example.com
            RECURRENCE-ID;TZID=Europe/Berlin:20260518T100000
            DTSTART;TZID=Europe/Berlin:20260518T150000
            DURATION:PT30M
            END:VEVENT
            """
        )

      result = edit!(document, "20260525T100000", moved_to(~D[2026-05-26], 9), nil)

      master = master_of(result)
      assert "RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=10" in master
      assert "DTSTART;TZID=Europe/Berlin:20260505T090000" in master
      assert "EXDATE;TZID=Europe/Berlin:20260512T090000" in master

      [override] = overrides_of(result)
      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260519T090000" in override
      assert "DTSTART;TZID=Europe/Berlin:20260519T140000" in override
    end

    test "every weekday of the rule turns by the same days, in the order written" do
      assert rule_after("FREQ=WEEKLY;BYDAY=MO,WE,FR", ~D[2026-05-26], 10) ==
               "RRULE:FREQ=WEEKLY;BYDAY=TU,TH,SA"

      assert rule_after("FREQ=WEEKLY;BYDAY=FR,MO", ~D[2026-05-26], 10) ==
               "RRULE:FREQ=WEEKLY;BYDAY=SA,TU"

      assert rule_after("FREQ=WEEKLY;BYDAY=MO", ~D[2026-05-24], 10) ==
               "RRULE:FREQ=WEEKLY;BYDAY=SU"
    end

    test "a move on the same day leaves the rule as written" do
      assert rule_after("FREQ=WEEKLY;BYDAY=MO", ~D[2026-05-25], 11) ==
               "RRULE:FREQ=WEEKLY;BYDAY=MO"
    end

    test "a Sunday weekday wraps to Monday in a weekly rule" do
      # Monday to Tuesday moves the rule's Sunday past WKST, to Monday.
      assert rule_after("FREQ=WEEKLY;BYDAY=MO,SU;WKST=MO", ~D[2026-05-26], 10) ==
               "RRULE:FREQ=WEEKLY;BYDAY=TU,MO;WKST=MO"
    end

    test "an every-other-week rule is refused only when a weekday wraps past WKST" do
      document = weekly("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,SU;WKST=MO")

      assert Series.edit_master(document, "20260525T100000", moved_to(~D[2026-05-26], 10), nil) ==
               {:error, :rule_pins_occurrences}

      assert rule_after("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=MO", ~D[2026-05-26], 10) ==
               "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;WKST=MO"
    end

    for rule <- [
          "FREQ=MONTHLY;BYDAY=2MO",
          "FREQ=MONTHLY;BYMONTHDAY=4",
          "FREQ=YEARLY;BYMONTH=5",
          "FREQ=WEEKLY;BYDAY=MO;BYSETPOS=1"
        ] do
      test "#{rule} cannot follow a move to another date" do
        assert Series.edit_master(
                 weekly(unquote(rule)),
                 "20260525T100000",
                 moved_to(~D[2026-05-26], 10),
                 nil
               ) == {:error, :rule_pins_occurrences}
      end
    end

    test "a rule naming the hour refuses any move" do
      assert Series.edit_master(
               weekly("FREQ=WEEKLY;BYHOUR=10"),
               "20260525T100000",
               moved_to(~D[2026-05-25], 11),
               nil
             ) == {:error, :rule_pins_occurrences}
    end
  end

  describe "round trip through the sync's parser and normaliser" do
    defp berlin_instant(%Date{} = date, %Time{} = time),
      do: date |> DateTime.new!(time, "Europe/Berlin") |> DateTime.shift_zone!("Etc/UTC")

    test "a Monday series moved to Tuesday shows every occurrence on a Tuesday" do
      {winter, summer} = winter_and_summer_mondays()
      excluded = Date.add(summer, -7)
      overridden = Date.add(summer, 7)

      document =
        calendar(
          @vtimezone <>
            String.replace(
              master(
                "DTSTART;TZID=Europe/Berlin:#{stamp(winter)}T100000",
                "EXDATE;TZID=Europe/Berlin:#{stamp(excluded)}T100000\n"
              ),
              "RRULE:FREQ=WEEKLY",
              "RRULE:FREQ=WEEKLY;BYDAY=MO"
            ) <>
            """
            BEGIN:VEVENT
            UID:weekly-sync@example.com
            RECURRENCE-ID;TZID=Europe/Berlin:#{stamp(overridden)}T100000
            DTSTART;TZID=Europe/Berlin:#{stamp(overridden)}T150000
            DURATION:PT30M
            SUMMARY:Moved
            END:VEVENT
            """
        )

      # Monday 10:00 to Tuesday 09:00: a day, less an hour.
      new_start = berlin_instant(Date.add(summer, 1), ~T[09:00:00])
      changes = %{start_time: new_start, end_time: DateTime.add(new_start, 30, :minute)}

      before = normalised_events(document)
      events = normalised_events(edit!(document, "#{stamp(summer)}T100000", changes, nil))
      uids = Enum.map(events, & &1.uid)
      uid = &"weekly-sync@example.com_#{stamp(Date.add(&1, 1))}T090000"

      assert before != []
      assert length(events) == length(before)
      assert Enum.uniq(uids) == uids

      assert Enum.reject(events, &(berlin_weekday(&1.start_at) == 2 or &1.summary == "Moved")) ==
               []

      refute uid.(excluded) in uids
      assert [override] = Enum.filter(events, &(&1.uid == uid.(overridden)))
      assert override.summary == "Moved"

      assert DateTime.compare(
               override.start_at,
               berlin_instant(Date.add(overridden, 1), ~T[14:00:00])
             ) == :eq
    end

    defp berlin_weekday(instant),
      do: instant |> DateTime.shift_zone!("Europe/Berlin") |> Date.day_of_week()

    test "a moved series keeps its exceptions excluded and each override over its own slot" do
      {winter, summer} = winter_and_summer_mondays()
      excluded = Date.add(summer, -7)
      overridden = Date.add(summer, 7)

      document =
        calendar(
          @vtimezone <>
            master(
              "DTSTART;TZID=Europe/Berlin:#{stamp(winter)}T100000",
              "EXDATE;TZID=Europe/Berlin:#{stamp(excluded)}T100000\n"
            ) <>
            """
            BEGIN:VEVENT
            UID:weekly-sync@example.com
            RECURRENCE-ID;TZID=Europe/Berlin:#{stamp(overridden)}T100000
            DTSTART;TZID=Europe/Berlin:#{stamp(overridden)}T150000
            DURATION:PT30M
            SUMMARY:Moved
            END:VEVENT
            """
        )

      new_start = berlin_instant(summer, ~T[11:00:00])
      changes = %{start_time: new_start, end_time: DateTime.add(new_start, 30, :minute)}

      before = normalised_events(document)
      events = normalised_events(edit!(document, "#{stamp(summer)}T100000", changes, nil))
      uids = Enum.map(events, & &1.uid)
      uid = &"weekly-sync@example.com_#{stamp(&1)}T110000"

      assert length(events) == length(before)
      assert Enum.uniq(uids) == uids
      refute Enum.any?(uids, &String.ends_with?(&1, "T100000"))

      # Excluded before the move, excluded after it.
      refute uid.(excluded) in uids

      # Filed once, over its moved slot, and still an hour after 15:00.
      assert [override] = Enum.filter(events, &(&1.uid == uid.(overridden)))
      assert override.summary == "Moved"

      assert DateTime.compare(override.start_at, berlin_instant(overridden, ~T[16:00:00])) ==
               :eq

      edited = Enum.find(events, &(&1.uid == uid.(summer)))
      assert DateTime.compare(edited.start_at, new_start) == :eq

      winter_occurrence = Enum.find(events, &(&1.uid == uid.(winter)))

      assert DateTime.compare(winter_occurrence.start_at, berlin_instant(winter, ~T[11:00:00])) ==
               :eq
    end
  end
end
