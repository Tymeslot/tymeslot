defmodule Tymeslot.Integrations.Calendar.ICalBuilder.SeriesSplitTest do
  @moduledoc """
  Splitting a recurring event stored as one CalDAV resource in two at one of
  its occurrences, for an edit of it and every following one
  (`Series.split/5`).

  The head is the original resource ended before the slot, the tail a new
  one starting at it. The round trips at the bottom read both back through
  the sync's parser and normaliser, which is where a miscounted tail or a
  head that runs on shows: as occurrences the series never had, or shown
  twice.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  import Tymeslot.Test.ICalSeriesFixtures

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series

  @vtimezone vtimezone()

  # A weekly Berlin series of ten from Monday 5 January 2026 (winter,
  # UTC+1), with an occurrence excluded and one moved on each side of the
  # 26 January occurrence, the fourth, where it is split.
  @berlin_master """
  BEGIN:VEVENT
  UID:weekly-sync@example.com
  DTSTAMP:20260101T090000Z
  DTSTART;TZID=Europe/Berlin:20260105T100000
  DTEND;TZID=Europe/Berlin:20260105T103000
  RRULE:FREQ=WEEKLY;COUNT=10
  EXDATE;TZID=Europe/Berlin:20260112T100000,20260209T100000
  SUMMARY:Weekly sync
  ATTENDEE;PARTSTAT=ACCEPTED:mailto:ada@example.com
  X-EXAMPLE-FLAG:kept
  BEGIN:VALARM
  ACTION:DISPLAY
  TRIGGER:-PT10M
  END:VALARM
  END:VEVENT
  """

  defp berlin_override(date, summary) do
    """
    BEGIN:VEVENT
    UID:weekly-sync@example.com
    DTSTAMP:20260101T090000Z
    RECURRENCE-ID;TZID=Europe/Berlin:#{date}T100000
    DTSTART;TZID=Europe/Berlin:#{date}T150000
    DTEND;TZID=Europe/Berlin:#{date}T153000
    SUMMARY:#{summary}
    END:VEVENT
    """
  end

  @split_key "20260126T100000"

  defp berlin_document do
    calendar(
      @vtimezone <>
        @berlin_master <>
        berlin_override("20260119", "Earlier, moved") <>
        berlin_override("20260216", "Later, moved")
    )
  end

  defp split!(document, key, changes \\ %{}, timezone \\ nil) do
    assert {:ok, %{head: head, tail: tail, tail_uid: uid}} =
             Series.split(document, key, changes, timezone)

    {head, tail, uid}
  end

  defp master_of(document), do: document |> vevents() |> Enum.find(&(not recurrence_id?(&1)))
  defp overrides_of(document), do: document |> vevents() |> Enum.filter(&recurrence_id?/1)
  defp recurrence_id?(vevent), do: Enum.any?(vevent, &String.starts_with?(&1, "RECURRENCE-ID"))
  defp rrule_of(document), do: document |> master_of() |> Enum.find(&(&1 =~ ~r/^RRULE/))

  describe "split/5, the head" do
    test "a zoned series ends a second before the slot, as a UTC instant, its COUNT gone" do
      {head, _tail, _uid} = split!(berlin_document(), @split_key)

      # 26 January, 10:00 in Berlin (UTC+1), is 09:00 UTC.
      assert rrule_of(head) == "RRULE:FREQ=WEEKLY;UNTIL=20260126T085959Z"
    end

    test "a UTC series ends a second before the slot, in UTC" do
      document = calendar(master("DTSTART:20260105T090000Z"))
      {head, _tail, _uid} = split!(document, "20260126T090000")

      assert rrule_of(head) == "RRULE:FREQ=WEEKLY;UNTIL=20260126T085959Z"
    end

    test "an all-day series ends the day before the slot, as a date" do
      document = calendar(master("DTSTART;VALUE=DATE:20260105"))
      {head, _tail, _uid} = split!(document, "20260126")

      assert rrule_of(head) == "RRULE:FREQ=WEEKLY;UNTIL=20260125"
    end

    test "a floating series ends a second before the slot, as a floating wall clock" do
      document = calendar(master("DTSTART:20260105T100000"))
      {head, _tail, _uid} = split!(document, "20260126T100000")

      assert rrule_of(head) == "RRULE:FREQ=WEEKLY;UNTIL=20260126T095959"
    end

    test "keeps the exceptions and overrides before the slot and drops the rest" do
      {head, _tail, _uid} = split!(berlin_document(), @split_key)

      assert "EXDATE;TZID=Europe/Berlin:20260112T100000" in master_of(head)
      refute Enum.any?(lines(head), &(&1 =~ "20260209"))

      assert [override] = overrides_of(head)
      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260119T100000" in override
      assert "UID:weekly-sync@example.com" in override
    end

    test "takes none of the edit" do
      {head, _tail, _uid} = split!(berlin_document(), @split_key, %{summary: "Renamed"})

      assert "SUMMARY:Weekly sync" in master_of(head)
      assert "DTSTART;TZID=Europe/Berlin:20260105T100000" in master_of(head)
    end
  end

  describe "split/5, the tail" do
    test "starts at the slot in the master's zone, under a new UID" do
      {_head, tail, uid} = split!(berlin_document(), @split_key)
      master = master_of(tail)

      assert uid != "weekly-sync@example.com"
      assert "UID:#{uid}" in master
      assert "DTSTART;TZID=Europe/Berlin:20260126T100000" in master
      assert "DTEND;TZID=Europe/Berlin:20260126T103000" in master
    end

    test "a COUNT of ten split at the fourth leaves seven, excluded occurrences counted" do
      {_head, tail, _uid} = split!(berlin_document(), @split_key)

      assert rrule_of(tail) == "RRULE:FREQ=WEEKLY;COUNT=7"
    end

    test "keeps an UNTIL as it was" do
      document = String.replace(berlin_document(), "COUNT=10", "UNTIL=20260316T085959Z")

      {_head, tail, _uid} = split!(document, @split_key)

      assert rrule_of(tail) == "RRULE:FREQ=WEEKLY;UNTIL=20260316T085959Z"
    end

    test "carries the exceptions and overrides from the slot on, under the new UID" do
      {_head, tail, uid} = split!(berlin_document(), @split_key)

      assert "EXDATE;TZID=Europe/Berlin:20260209T100000" in master_of(tail)
      refute Enum.any?(lines(tail), &(&1 =~ "20260112"))

      assert [override] = overrides_of(tail)
      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260216T100000" in override
      assert "UID:#{uid}" in override
      assert "SUMMARY:Later, moved" in override
    end

    test "copies the time zone, attendees, alarms and other properties" do
      {_head, tail, _uid} = split!(berlin_document(), @split_key)
      master = master_of(tail)

      assert String.contains?(tail, "BEGIN:VTIMEZONE")
      assert "ATTENDEE;PARTSTAT=ACCEPTED:mailto:ada@example.com" in master
      assert "X-EXAMPLE-FLAG:kept" in master
      assert "TRIGGER:-PT10M" in master
    end

    test "takes the edit, moving its own slots with it" do
      # 26 January, 11:00 in Berlin (UTC+1): an hour later.
      changes = %{
        summary: "Renamed",
        start_time: ~U[2026-01-26 10:00:00Z],
        end_time: ~U[2026-01-26 10:30:00Z]
      }

      {_head, tail, _uid} = split!(berlin_document(), @split_key, changes)
      master = master_of(tail)

      assert "SUMMARY:Renamed" in master
      assert "DTSTART;TZID=Europe/Berlin:20260126T110000" in master
      assert "EXDATE;TZID=Europe/Berlin:20260209T110000" in master
      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260216T110000" in hd(overrides_of(tail))
    end

    test "a move takes the UNTIL along, so the last occurrence stays" do
      # UNTIL at the last occurrence's start, 16 March 10:00 in Berlin.
      document = String.replace(berlin_document(), "COUNT=10", "UNTIL=20260316T090000Z")
      changes = %{start_time: ~U[2026-01-26 10:00:00Z], end_time: ~U[2026-01-26 10:30:00Z]}

      {_head, tail, _uid} = split!(document, @split_key, changes)

      assert rrule_of(tail) == "RRULE:FREQ=WEEKLY;UNTIL=20260316T100000Z"
    end

    test "is refused where the whole series would be" do
      changes = %{start_time: ~D[2026-01-26], end_time: ~D[2026-01-27]}

      assert Series.split(berlin_document(), @split_key, changes, nil) ==
               {:error, :value_type_change}
    end
  end

  describe "split/5 of a series with a COUNT" do
    defp utc_series(rule, first \\ "20260101") do
      "DTSTART:#{first}T100000Z"
      |> master()
      |> String.replace("RRULE:FREQ=WEEKLY", "RRULE:" <> rule)
      |> calendar()
    end

    test "refuses a COUNT over days of the month, which it cannot count" do
      # The 1st and 15th of each month: 1 March is the fifth occurrence, so
      # a tail of 19 would be right, and a count stepping monthly makes 21.
      document = utc_series("FREQ=MONTHLY;BYMONTHDAY=1,15;COUNT=24")

      assert Series.split(document, "20260301T100000", %{summary: "Renamed"}, nil) ==
               {:error, :unsupported_rule}
    end

    test "refuses a COUNT over an ordinal weekday, which it cannot count" do
      # The second Monday of each month from 12 January: 9 March is the
      # third, so a tail of 10 would be right, and reading 2MO as MO makes 11.
      document = utc_series("FREQ=MONTHLY;BYDAY=2MO;COUNT=12", "20260112")

      assert Series.split(document, "20260309T100000", %{summary: "Renamed"}, nil) ==
               {:error, :unsupported_rule}
    end

    test "still ends such a series with an UNTIL when only the head is wanted" do
      document = utc_series("FREQ=MONTHLY;BYMONTHDAY=1,15;COUNT=24")

      assert {:ok, head} = Series.truncate(document, "20260301T100000", nil)
      assert rrule_of(head) == "RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15;UNTIL=20260301T095959Z"
    end

    test "counts past the expander's cap on occurrences" do
      # Day 601 of 800: 600 come before it, so 200 are left.
      document = utc_series("FREQ=DAILY;COUNT=800")
      key = Calendar.strftime(Date.add(~D[2026-01-01], 600), "%Y%m%dT100000")

      {_head, tail, _uid} = split!(document, key)

      assert rrule_of(tail) == "RRULE:FREQ=DAILY;COUNT=200"
    end
  end

  describe "split/5 at the first occurrence" do
    test "is an edit of every occurrence" do
      assert Series.split(berlin_document(), "20260105T100000", %{summary: "Renamed"}, nil) ==
               :first_occurrence
    end
  end

  describe "truncate/3" do
    test "is the head of the split alone" do
      {head, _tail, _uid} = split!(berlin_document(), @split_key, %{summary: "Renamed"})

      assert Series.truncate(berlin_document(), @split_key, nil) == {:ok, head}
    end
  end

  describe "round trip through the sync's parser and normaliser" do
    defp berlin_instant(%Date{} = date, %Time{} = time),
      do: date |> DateTime.new!(time, "Europe/Berlin") |> DateTime.shift_zone!("Etc/UTC")

    defp later_on_the_wall(instant, seconds) do
      instant
      |> DateTime.shift_zone!("Europe/Berlin")
      |> DateTime.to_naive()
      |> NaiveDateTime.add(seconds)
      |> DateTime.from_naive!("Europe/Berlin")
      |> DateTime.shift_zone!("Etc/UTC")
    end

    defp starts(events), do: events |> Enum.map(& &1.start_at) |> Enum.sort(DateTime)

    # 26 weekly occurrences from a winter Monday, the last in early summer, so
    # the tail runs across the change to summer time. One occurrence is
    # excluded and one moved on each side of the sixth, where it is split.
    defp round_trip_document(winter) do
      week = &Date.add(winter, 7 * &1)

      override = fn date, summary ->
        """
        BEGIN:VEVENT
        UID:weekly-sync@example.com
        RECURRENCE-ID;TZID=Europe/Berlin:#{stamp(date)}T100000
        DTSTART;TZID=Europe/Berlin:#{stamp(date)}T150000
        DURATION:PT30M
        SUMMARY:#{summary}
        END:VEVENT
        """
      end

      calendar(
        @vtimezone <>
          String.replace(
            master(
              "DTSTART;TZID=Europe/Berlin:#{stamp(winter)}T100000",
              "EXDATE;TZID=Europe/Berlin:#{stamp(week.(2))}T100000,#{stamp(week.(12))}T100000\n"
            ),
            "RRULE:FREQ=WEEKLY",
            "RRULE:FREQ=WEEKLY;COUNT=26"
          ) <> override.(week.(1), "Earlier, moved") <> override.(week.(15), "Later, moved")
      )
    end

    test "the head stops before the slot, the tail starts there edited, and nothing is lost" do
      {winter, _summer} = winter_and_summer_mondays()
      slot_date = Date.add(winter, 5 * 7)
      slot = berlin_instant(slot_date, ~T[10:00:00])
      document = round_trip_document(winter)

      # An hour later, on the wall clock of every following occurrence.
      moved = later_on_the_wall(slot, 3600)
      changes = %{summary: "Renamed", start_time: moved, end_time: DateTime.add(moved, 1800)}

      {head, tail, _uid} = split!(document, "#{stamp(slot_date)}T100000", changes)

      before = normalised_events(document)
      head_events = normalised_events(head)
      tail_events = normalised_events(tail)

      # 26 occurrences, one excluded on each side.
      assert length(before) == 24

      {earlier, following} = Enum.split_with(before, &DateTime.before?(&1.start_at, slot))
      assert starts(head_events) == starts(earlier)

      assert starts(tail_events) ==
               following |> Enum.map(&later_on_the_wall(&1.start_at, 3600)) |> Enum.sort(DateTime)

      assert hd(starts(tail_events)) == moved
      union = starts(head_events) ++ starts(tail_events)
      assert Enum.uniq(union) == union

      # The edit reached the tail's occurrences and none of the head's.
      assert Enum.reject(tail_events, &(&1.summary in ["Renamed", "Later, moved"])) == []
      assert Enum.reject(head_events, &(&1.summary in ["Weekly sync", "Earlier, moved"])) == []
    end

    test "a tail running into summer time keeps the wall clock of the series" do
      {winter, _summer} = winter_and_summer_mondays()
      slot_date = Date.add(winter, 5 * 7)

      {_head, tail, _uid} =
        split!(round_trip_document(winter), "#{stamp(slot_date)}T100000", %{summary: "Renamed"})

      berlin_times =
        tail
        |> normalised_events()
        |> Enum.reject(&(&1.summary == "Later, moved"))
        |> Enum.map(&(&1.start_at |> DateTime.shift_zone!("Europe/Berlin") |> DateTime.to_time()))
        |> Enum.uniq()

      assert berlin_times == [~T[10:00:00]]
    end
  end
end
