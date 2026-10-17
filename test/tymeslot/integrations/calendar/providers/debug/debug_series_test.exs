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

  defp listed do
    {:ok, events} =
      DebugCalendarProvider.list_events(%{user_id: 1},
        start_time: ~U[2026-10-12 00:00:00Z],
        end_time: ~U[2026-11-02 00:00:00Z]
      )

    {:ok, normalised} =
      DebugCalendarProvider.normalise_events(events, %{
        calendar_integration_id: 42,
        provider_calendar_id: "default",
        synced_at: ~U[2026-10-12 00:00:00Z]
      })

    Enum.sort_by(normalised, & &1.start_at, DateTime)
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
end
