defmodule Tymeslot.Integrations.Calendar.ICalBuilder.SeriesOverrideTest do
  @moduledoc """
  Editing one occurrence of a recurring event stored as a single CalDAV
  resource: the occurrence's override `VEVENT`, named by a `RECURRENCE-ID`
  in the form of the master's `DTSTART`, is written or made from the master.

  Its timing has to read as the series does, the wall clock in the master's
  zone across a DST change, so the round trips at the bottom feed the result
  back through the parser and normaliser the sync uses: an override the sync
  files under another uid, or at another time, is the bug however well formed
  the document looks.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  import Tymeslot.Test.ICalSeriesFixtures

  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series

  @vtimezone vtimezone()

  defp put!(document, key, changes, timezone) do
    assert {:ok, result} = Series.put_override(document, key, changes, timezone)
    result
  end

  defp exclude!(document, key, timezone) do
    assert {:ok, result} = Series.exclude_occurrence(document, key, timezone)
    result
  end

  describe "put_override/4 on a slot with no override yet" do
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

  describe "the series' zone is the master's, whatever zone the caller passes" do
    # Another client wrote this override entirely in UTC, so the cached row the
    # sync makes of it carries UTC as its zone; the master still says Berlin.
    defp series_with_utc_override do
      calendar(
        @vtimezone <>
          master("DTSTART;TZID=Europe/Berlin:20260504T100000") <>
          """
          BEGIN:VEVENT
          UID:weekly-sync@example.com
          DTSTAMP:20260401T090000Z
          RECURRENCE-ID:20260511T080000Z
          DTSTART:20260511T130000Z
          DURATION:PT30M
          SUMMARY:Moved in UTC
          END:VEVENT
          """
      )
    end

    test "put_override/4 finds the UTC override and writes Berlin wall clock" do
      result =
        put!(
          series_with_utc_override(),
          "20260511T100000",
          %{start_time: ~U[2026-05-11 12:00:00Z], end_time: ~U[2026-05-11 12:30:00Z]},
          "Etc/UTC"
        )

      assert [_master, override] = vevents(result)
      assert "RECURRENCE-ID:20260511T080000Z" in override
      assert "DTSTART;TZID=Europe/Berlin:20260511T140000" in override
    end

    test "exclude_occurrence/3 drops the UTC override" do
      result = exclude!(series_with_utc_override(), "20260511T100000", "Etc/UTC")

      refute "SUMMARY:Moved in UTC" in lines(result)
      assert "EXDATE;TZID=Europe/Berlin:20260511T100000" in lines(result)
    end

    test "the sync files the UTC override over the occurrence it replaces" do
      document =
        String.replace(series_with_utc_override(), "20260511T", "#{stamp_next_monday()}T")

      uids = document |> normalised() |> Map.keys()

      key = "weekly-sync@example.com_#{stamp_next_monday()}T100000"
      assert Enum.count(uids, &(&1 == key)) == 1
      refute "weekly-sync@example.com_#{stamp_next_monday()}T080000" in uids
    end

    # The fixture's 08:00Z is 10:00 in Berlin only in summer (UTC+2), so the
    # override is moved onto the next summer Monday, inside the sync's window.
    defp stamp_next_monday do
      today = Date.utc_today()
      july = Date.new!(today.year, 7, 13)
      july = if Date.compare(july, today) == :lt, do: Date.new!(today.year + 1, 7, 13), else: july
      july |> Date.beginning_of_week() |> Calendar.strftime("%Y%m%d")
    end
  end

  describe "round trip through the sync's parser and normaliser" do
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
  end
end
