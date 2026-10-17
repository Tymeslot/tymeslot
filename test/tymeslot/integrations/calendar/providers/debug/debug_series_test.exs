defmodule Tymeslot.Integrations.Calendar.DebugCalendarProvider.SeriesTest do
  @moduledoc """
  A repeating debug event lists as one row per occurrence, keyed and
  addressed the way the CalDAV family caches a series, so the calendar's
  scoped edits can be exercised on a development calendar.
  """

  use ExUnit.Case, async: false

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider
  alias Tymeslot.Integrations.Calendar.DebugStore

  setup do
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

    Enum.sort_by(normalised, & &1.uid)
  end

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
    {:ok, master} = DebugStore.fetch_event("standup")

    DebugStore.put_event(
      Map.merge(master, %{
        exdates: ["20261019T090000"],
        overrides: %{
          "20261026T090000" => %{
            start_time: ~U[2026-10-26 11:00:00Z],
            end_time: ~U[2026-10-26 11:30:00Z]
          }
        }
      })
    )

    assert [first, moved] = listed()
    assert first.uid == "standup_20261012T090000"
    assert moved.uid == "standup_20261026T090000"
    assert moved.start_at == ~U[2026-10-26 11:00:00Z]
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
    change_master(%{
      overrides: %{
        "20261102T090000" => %{
          start_time: ~U[2026-11-01 09:00:00Z],
          end_time: ~U[2026-11-01 09:15:00Z]
        }
      }
    })

    assert Enum.any?(listed(), &(&1.uid == "standup_20261102T090000"))

    refute Enum.any?(
             listed(~U[2026-11-02 00:00:00Z], ~U[2026-11-09 00:00:00Z]),
             &(&1.uid == "standup_20261102T090000")
           )
  end

  test "a renamed occurrence outside the range does not list at the master's time" do
    change_master(%{overrides: %{"20261109T090000" => %{summary: "Planning"}}})

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
    assert [row | _] = listed()
    assert row.timezone == "Etc/UTC"
  end

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
    assert first.end_date == ~D[2026-10-14]
    assert first.provider_event_id == "debug:holiday"
  end

  test "an override for a slot the rule no longer makes is not listed" do
    change_master(%{
      recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;UNTIL=20261025T235959Z",
      overrides: %{
        "20261102T090000" => %{
          start_time: ~U[2026-11-02 11:00:00Z],
          end_time: ~U[2026-11-02 11:30:00Z]
        }
      }
    })

    assert listed(~U[2026-10-26 00:00:00Z], ~U[2026-11-09 00:00:00Z]) == []
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

  test "an override that sets a start but no end keeps the series' length" do
    change_master(%{
      overrides: %{"20261019T090000" => %{start_time: ~U[2026-10-19 14:00:00Z]}}
    })

    assert moved = Enum.find(listed(), &(&1.uid == "standup_20261019T090000"))
    assert moved.start_at == ~U[2026-10-19 14:00:00Z]
    assert moved.end_at == ~U[2026-10-19 14:15:00Z]
  end
end
