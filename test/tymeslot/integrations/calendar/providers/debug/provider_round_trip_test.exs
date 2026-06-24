defmodule Tymeslot.Integrations.Calendar.DebugCalendarProvider.RoundTripTest do
  use ExUnit.Case, async: false

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider
  alias Tymeslot.Integrations.Calendar.DebugStore

  @client %{user_id: 1}

  setup do
    start_supervised!(DebugStore)
    # Use the empty pattern so only the events we create appear in list_events.
    DebugStore.set_pattern(:empty)
    :ok
  end

  defp context do
    %{
      calendar_integration_id: 42,
      provider_calendar_id: "default",
      synced_at: DateTime.utc_now()
    }
  end

  defp normalised_for(uid) do
    {:ok, events} =
      DebugCalendarProvider.list_events(@client,
        start_time: ~U[2026-06-01 00:00:00Z],
        end_time: ~U[2026-07-31 00:00:00Z]
      )

    {:ok, normalised} = DebugCalendarProvider.normalise_events(events, context())
    Enum.find(normalised, &(&1.uid == uid))
  end

  test "timed event round-trips with reminders and recurrence intact" do
    event_data = %{
      uid: "evt-timed",
      summary: "Weekly sync",
      description: "Status update",
      location: "Room 1",
      all_day: false,
      start_time: ~U[2026-06-15 10:00:00Z],
      end_time: ~U[2026-06-15 11:00:00Z],
      reminders: [%{method: :popup, minutes_before: 10}],
      recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
      calendar_integration_id: 42,
      calendar_id: "default"
    }

    assert {:ok, %{uid: "evt-timed"}} = DebugCalendarProvider.create_event(@client, event_data)

    assert %CalendarEvent{
             uid: "evt-timed",
             provider: :debug,
             all_day: false,
             start_at: ~U[2026-06-15 10:00:00Z],
             end_at: ~U[2026-06-15 11:00:00Z],
             start_date: nil,
             summary: "Weekly sync",
             description: "Status update",
             location: "Room 1",
             recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
             reminders: [%{method: :popup, minutes_before: 10}],
             status: :confirmed,
             transparency: :opaque,
             created_by_tymeslot: true
           } = normalised_for("evt-timed")
  end

  test "update_event adds a colour reflected after normalisation" do
    create = %{
      uid: "evt-colour",
      summary: "Plan",
      all_day: false,
      start_time: ~U[2026-06-16 09:00:00Z],
      end_time: ~U[2026-06-16 09:30:00Z]
    }

    DebugCalendarProvider.create_event(@client, create)

    assert %CalendarEvent{colour: nil} = normalised_for("evt-colour")

    update = Map.merge(create, %{colour: "tomato", summary: "Plan v2"})
    assert :ok = DebugCalendarProvider.update_event(@client, "evt-colour", update)

    assert %CalendarEvent{colour: "tomato", summary: "Plan v2"} = normalised_for("evt-colour")
  end

  test "all-day event normalises to start_date/end_date with no start_at" do
    event_data = %{
      uid: "evt-allday",
      summary: "Conference",
      all_day: true,
      start_time: ~D[2026-06-20],
      end_time: ~D[2026-06-21]
    }

    assert {:ok, %{uid: "evt-allday"}} = DebugCalendarProvider.create_event(@client, event_data)

    assert %CalendarEvent{
             uid: "evt-allday",
             all_day: true,
             start_date: ~D[2026-06-20],
             end_date: ~D[2026-06-21],
             start_at: nil,
             end_at: nil
           } = normalised_for("evt-allday")
  end

  test "delete_event removes the event from later listings" do
    event_data = %{
      uid: "evt-del",
      summary: "Temp",
      all_day: false,
      start_time: ~U[2026-06-17 12:00:00Z],
      end_time: ~U[2026-06-17 13:00:00Z]
    }

    DebugCalendarProvider.create_event(@client, event_data)
    assert %CalendarEvent{uid: "evt-del"} = normalised_for("evt-del")

    assert :ok = DebugCalendarProvider.delete_event(@client, "evt-del", [])
    assert normalised_for("evt-del") == nil
  end
end
