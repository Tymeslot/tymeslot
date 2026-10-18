defmodule Tymeslot.Integrations.Calendar.DebugCalendarProvider.SeriesTest do
  @moduledoc """
  A repeating debug event lists as one row per occurrence, keyed and
  addressed the way the CalDAV family caches a series, and takes the
  calendar's scoped edits and deletes answered as the CalDAV writer answers
  them, so they can be exercised on a development calendar.
  """

  use ExUnit.Case, async: false

  @moduletag :calendar

  import Tymeslot.Test.ClockHelpers, only: [freeze_clock: 1]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider
  alias Tymeslot.Integrations.Calendar.DebugStore

  setup do
    # A series expands over the window every sync reads, around "now".
    freeze_clock(~U[2026-10-14 12:00:00Z])
    start_supervised!(DebugStore)
    DebugStore.set_pattern(:empty)

    DebugStore.put_event(%{
      uid: "standup",
      summary: "Standup",
      all_day: false,
      start_time: ~U[2026-10-05 09:00:00Z],
      end_time: ~U[2026-10-05 09:15:00Z],
      recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
    })

    :ok
  end

  # The rows overlapping the range: a series lists every occurrence in the
  # sync window, as a CalDAV series does, and the cache's readers trim them.
  defp listed(range_start \\ ~U[2026-10-12 00:00:00Z], range_end \\ ~U[2026-11-02 00:00:00Z]) do
    {:ok, events} =
      DebugCalendarProvider.list_events(%{user_id: 1},
        start_time: range_start,
        end_time: range_end
      )

    {:ok, normalised} =
      DebugCalendarProvider.normalise_events(events, %{
        calendar_integration_id: 42,
        provider_calendar_id: "default",
        synced_at: ~U[2026-10-12 00:00:00Z]
      })

    normalised
    |> Enum.filter(&overlaps?(&1, range_start, range_end))
    |> Enum.sort_by(& &1.uid)
  end

  defp overlaps?(%CalendarEvent{all_day: true} = row, range_start, range_end),
    do:
      Date.compare(row.start_date, DateTime.to_date(range_end)) == :lt and
        Date.compare(row.end_date, DateTime.to_date(range_start)) == :gt

  defp overlaps?(row, range_start, range_end),
    do:
      DateTime.compare(row.start_at, range_end) == :lt and
        DateTime.compare(row.end_at, range_start) == :gt

  defp change_master(changes) do
    {:ok, master} = DebugStore.fetch_event("standup")
    DebugStore.put_event(Map.merge(master, changes))
  end

  test "lists one row per occurrence in range, keyed and addressed like a CalDAV series" do
    assert [first, second, third] = listed()

    assert %CalendarEvent{
             uid: "standup_20261012T090000",
             provider_event_id: "debug:standup",
             provider_metadata: %{uid: "standup"},
             recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
             start_at: ~U[2026-10-12 09:00:00Z],
             end_at: ~U[2026-10-12 09:15:00Z]
           } = first

    assert second.uid == "standup_20261019T090000"
    assert third.uid == "standup_20261026T090000"
  end

  test "a skipped occurrence is left out and a changed one is listed as changed" do
    {:ok, _deleted} = delete_occurrence("20261019T090000")

    {:ok, _written} =
      write(:this_only, "20261026T090000", %{
        start_time: ~U[2026-10-26 11:00:00Z],
        end_time: ~U[2026-10-26 11:30:00Z]
      })

    assert [first, moved] = listed()
    assert first.uid == "standup_20261012T090000"
    assert moved.uid == "standup_20261026T090000"
    assert moved.start_at == ~U[2026-10-26 11:00:00Z]
  end

  test "the dev calendar's busy blocks are the series' occurrences, moved and skipped ones included" do
    {:ok, _deleted} = delete_occurrence("20261019T090000")

    {:ok, _written} =
      write(:this_only, "20261026T090000", %{
        start_time: ~U[2026-10-26 11:00:00Z],
        end_time: ~U[2026-10-26 11:30:00Z]
      })

    blocks =
      DebugCalendarProvider.stored_events_in_range(
        ~U[2026-10-12 00:00:00Z],
        ~U[2026-11-02 00:00:00Z]
      )

    assert blocks |> Enum.map(&{&1.start_time, &1.end_time}) |> Enum.sort() == [
             {~U[2026-10-12 09:00:00Z], ~U[2026-10-12 09:15:00Z]},
             {~U[2026-10-26 11:00:00Z], ~U[2026-10-26 11:30:00Z]}
           ]

    assert Enum.all?(blocks, &(&1.uid == "standup" and &1.status == "confirmed"))
  end

  test "an event that does not repeat lists as itself" do
    DebugStore.put_event(%{
      uid: "dentist",
      summary: "Dentist",
      all_day: false,
      start_time: ~U[2026-10-14 15:00:00Z],
      end_time: ~U[2026-10-14 16:00:00Z]
    })

    assert Enum.any?(listed(), &(&1.uid == "dentist" and is_nil(&1.provider_event_id)))
  end

  test "an occurrence moved across the range boundary lists only where it now is" do
    {:ok, _written} =
      write(:this_only, "20261102T090000", %{
        start_time: ~U[2026-11-01 09:00:00Z],
        end_time: ~U[2026-11-01 09:15:00Z]
      })

    assert Enum.any?(listed(), &(&1.uid == "standup_20261102T090000"))

    refute Enum.any?(
             listed(~U[2026-11-02 00:00:00Z], ~U[2026-11-09 00:00:00Z]),
             &(&1.uid == "standup_20261102T090000")
           )
  end

  test "a renamed occurrence outside the range does not list at the master's time" do
    {:ok, _written} = write(:this_only, "20261109T090000", %{summary: "Planning"})

    assert ["standup_20261005T090000"] =
             Enum.map(listed(~U[2026-10-05 00:00:00Z], ~U[2026-10-06 00:00:00Z]), & &1.uid)
  end

  test "a timed occurrence that started before the range but overlaps it is listed" do
    change_master(%{end_time: ~U[2026-10-05 11:00:00Z]})

    assert Enum.any?(
             listed(~U[2026-10-12 10:00:00Z], ~U[2026-10-13 00:00:00Z]),
             &(&1.uid == "standup_20261012T090000")
           )
  end

  test "a series keeps its zone: keys are local wall-clock across a DST end" do
    change_master(%{
      timezone: "Europe/Warsaw",
      start_time: ~U[2026-10-05 07:00:00Z],
      end_time: ~U[2026-10-05 07:15:00Z]
    })

    rows = listed(~U[2026-10-12 00:00:00Z], ~U[2026-11-03 00:00:00Z])

    assert Enum.map(rows, & &1.uid) == [
             "standup_20261012T090000",
             "standup_20261019T090000",
             "standup_20261026T090000",
             "standup_20261102T090000"
           ]

    assert Enum.map(rows, &DateTime.to_iso8601(DateTime.shift_zone!(&1.start_at, "Etc/UTC"))) == [
             "2026-10-12T07:00:00Z",
             "2026-10-19T07:00:00Z",
             "2026-10-26T08:00:00Z",
             "2026-11-02T08:00:00Z"
           ]

    assert Enum.all?(rows, &(&1.timezone == "Europe/Warsaw"))
  end

  test "an unknown stored zone does not crash listing" do
    change_master(%{timezone: "Mars/Olympus"})
    assert [row | _rest] = listed()
    assert row.timezone == "Etc/UTC"
  end

  # The end date is exclusive, as the cache keeps every all-day event.
  test "a repeating all-day event keys by date and lists on the range's first day west of UTC" do
    DebugStore.put_event(%{
      uid: "holiday",
      summary: "Holiday",
      all_day: true,
      start_time: ~D[2026-10-07],
      end_time: ~D[2026-10-07],
      recurrence_rule: "FREQ=WEEKLY;BYDAY=WE"
    })

    rows = listed(~U[2026-10-14 04:00:00Z], ~U[2026-10-21 04:00:00Z])
    assert first = Enum.find(rows, &(&1.uid == "holiday_20261014"))
    assert first.all_day
    assert first.start_date == ~D[2026-10-14]
    assert first.end_date == ~D[2026-10-15]
    assert first.provider_event_id == "debug:holiday"
  end

  test "an occurrence longer than a day lists in a range inside its span" do
    change_master(%{
      start_time: ~U[2026-10-09 09:00:00Z],
      end_time: ~U[2026-10-12 09:00:00Z],
      recurrence_rule: "FREQ=WEEKLY;BYDAY=FR"
    })

    assert [row] = listed(~U[2026-10-11 00:00:00Z], ~U[2026-10-12 00:00:00Z])
    assert row.uid == "standup_20261009T090000"
  end

  test "moving an occurrence without saying when it ends is refused, as on CalDAV" do
    assert {:error, :missing_timing} =
             write(:this_only, "20261019T090000", %{start_time: ~U[2026-10-19 14:00:00Z]})

    assert Enum.find(listed(), &(&1.uid == "standup_20261019T090000")).start_at ==
             ~U[2026-10-19 09:00:00Z]
  end

  defp write(scope, key, changes) do
    DebugCalendarProvider.update_event(nil, "standup_#{key}", %{
      occurrence: %{href: "debug:standup", key: key, scope: scope, changes: changes}
    })
  end

  defp delete_occurrence(key) do
    DebugCalendarProvider.delete_event(nil, "debug:standup",
      provider_event_id: "debug:standup",
      occurrence: %{href: "debug:standup", key: key}
    )
  end

  defp starts, do: listed() |> Enum.map(& &1.start_at) |> Enum.sort(DateTime)

  test "this event only moves the one occurrence" do
    assert {:ok, %{document: _document}} =
             write(:this_only, "20261019T090000", %{
               start_time: ~U[2026-10-19 10:00:00Z],
               end_time: ~U[2026-10-19 10:15:00Z]
             })

    assert starts() == [
             ~U[2026-10-12 09:00:00Z],
             ~U[2026-10-19 10:00:00Z],
             ~U[2026-10-26 09:00:00Z]
           ]
  end

  test "all events moves every occurrence by the same amount" do
    assert {:ok, %{document: _document}} =
             write(:all, "20261019T090000", %{
               start_time: ~U[2026-10-19 09:30:00Z],
               end_time: ~U[2026-10-19 10:00:00Z]
             })

    assert starts() == [
             ~U[2026-10-12 09:30:00Z],
             ~U[2026-10-19 09:30:00Z],
             ~U[2026-10-26 09:30:00Z]
           ]

    assert Enum.all?(listed(), &(DateTime.diff(&1.end_at, &1.start_at, :minute) == 30))
  end

  test "all events keeps a skipped and a changed occurrence on the same occurrences" do
    {:ok, %{document: _document}} = delete_occurrence("20261019T090000")
    {:ok, %{document: _document}} = write(:this_only, "20261026T090000", %{summary: "Retro"})

    assert {:ok, %{document: _document}} =
             write(:all, "20261012T090000", %{
               start_time: ~U[2026-10-12 09:30:00Z],
               end_time: ~U[2026-10-12 09:45:00Z]
             })

    rows = listed()
    assert Enum.map(rows, & &1.start_at) == [~U[2026-10-12 09:30:00Z], ~U[2026-10-26 09:30:00Z]]
    assert Enum.map(rows, & &1.summary) == ["Standup", "Retro"]
    assert Enum.map(rows, & &1.uid) == ["standup_20261012T093000", "standup_20261026T093000"]
  end

  test "this and following events splits the series at the occurrence" do
    assert {:ok, %{document: _document}} =
             write(:following, "20261019T090000", %{
               start_time: ~U[2026-10-19 14:00:00Z],
               end_time: ~U[2026-10-19 14:15:00Z]
             })

    assert starts() == [
             ~U[2026-10-12 09:00:00Z],
             ~U[2026-10-19 14:00:00Z],
             ~U[2026-10-26 14:00:00Z]
           ]
  end

  test "this and following events from the first occurrence edits the whole series" do
    assert {:ok, answer} = write(:following, "20261005T090000", %{summary: "Daily"})
    refute Map.has_key?(answer, :tail)

    assert Map.keys(DebugStore.snapshot().events) == ["standup"]
    assert Enum.all?(listed(), &(&1.summary == "Daily"))
  end

  test "deleting one occurrence skips it, and deleting the series removes it" do
    assert {:ok, %{document: document}} = delete_occurrence("20261019T090000")
    assert document =~ "EXDATE:20261019T090000Z"

    assert length(listed()) == 2

    assert :ok =
             DebugCalendarProvider.delete_event(nil, "debug:standup",
               provider_event_id: "debug:standup"
             )

    assert listed() == []
  end

  test "a debug series takes the calendar's scoped edits" do
    occurrence = %{provider: "debug", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"}

    assert Occurrence.series_family(occurrence) == :caldav
    assert Changes.repeatable_provider?("debug")
  end
end
