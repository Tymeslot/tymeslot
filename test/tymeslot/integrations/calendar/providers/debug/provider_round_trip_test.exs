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

  # A repeating event is kept as its CalDAV document and read back as a
  # CalDAV series is: the alarm stays in the document, but the cache does not
  # read alarms (or Tymeslot's authorship) back from any CalDAV calendar.
  test "timed repeating event round-trips with its recurrence, its alarm in its document" do
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
             uid: "evt-timed_20260615T100000",
             provider: :debug,
             all_day: false,
             start_at: ~U[2026-06-15 10:00:00Z],
             end_at: ~U[2026-06-15 11:00:00Z],
             start_date: nil,
             summary: "Weekly sync",
             description: "Status update",
             location: "Room 1",
             recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
             status: :confirmed,
             transparency: :opaque,
             provider_event_id: "debug:evt-timed"
           } = series = normalised_for("evt-timed_20260615T100000")

    assert series.raw_ical =~ "TRIGGER:-PT10M"
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

  test "an update for an unknown event without a start stores nothing" do
    assert {:error, :not_found} =
             DebugCalendarProvider.update_event(@client, "evt-unknown", %{summary: "Ghost"})

    assert DebugStore.fetch_event("evt-unknown") == :error

    assert {:error, :not_found} =
             DebugCalendarProvider.update_event(@client, "evt-unknown", %{
               summary: "Ghost",
               start_time: nil
             })

    assert DebugStore.fetch_event("evt-unknown") == :error
  end

  test "an update for an unknown event that says when it is creates it" do
    DebugCalendarProvider.update_event(@client, "evt-upsert", %{
      summary: "Upserted",
      start_time: ~U[2026-06-17 12:00:00Z],
      end_time: ~U[2026-06-17 13:00:00Z]
    })

    assert %CalendarEvent{uid: "evt-upsert"} = normalised_for("evt-upsert")
  end

  describe "a one-day all-day event, whose end date is exclusive" do
    setup do
      DebugCalendarProvider.create_event(@client, %{
        uid: "evt-day",
        summary: "Off",
        all_day: true,
        start_time: ~D[2026-06-20],
        end_time: ~D[2026-06-21]
      })

      :ok
    end

    defp uids_between(range_start, range_end) do
      {:ok, events} =
        DebugCalendarProvider.list_events(@client, start_time: range_start, end_time: range_end)

      events |> Enum.map(& &1.uid) |> Enum.sort()
    end

    test "is listed on its own day" do
      assert uids_between(~U[2026-06-20 00:00:00Z], ~U[2026-06-21 00:00:00Z]) == ["evt-day"]
    end

    test "does not overlap the next day" do
      assert uids_between(~U[2026-06-21 00:00:00Z], ~U[2026-06-22 00:00:00Z]) == []
    end

    test "reaches the dev calendar as a block ending where the next day starts" do
      assert [%{uid: "evt-day", end_time: ~D[2026-06-21]}] =
               DebugCalendarProvider.stored_events_in_range(
                 ~U[2026-06-20 00:00:00Z],
                 ~U[2026-06-21 00:00:00Z]
               )

      assert DebugCalendarProvider.stored_events_in_range(
               ~U[2026-06-21 00:00:00Z],
               ~U[2026-06-22 00:00:00Z]
             ) == []
    end
  end

  describe "free/busy" do
    test "a one-off event keeps it through a create and an update" do
      create = %{
        uid: "evt-free",
        summary: "Lunch",
        all_day: false,
        start_time: ~U[2026-06-18 12:00:00Z],
        end_time: ~U[2026-06-18 13:00:00Z],
        transparency: "transparent"
      }

      DebugCalendarProvider.create_event(@client, create)
      assert %CalendarEvent{transparency: :transparent} = normalised_for("evt-free")

      assert :ok =
               DebugCalendarProvider.update_event(
                 @client,
                 "evt-free",
                 Map.put(create, :transparency, "opaque")
               )

      assert %CalendarEvent{transparency: :opaque} = normalised_for("evt-free")
    end

    test "an event created without it is busy" do
      DebugCalendarProvider.create_event(@client, %{
        uid: "evt-busy",
        summary: "Review",
        all_day: false,
        start_time: ~U[2026-06-18 15:00:00Z],
        end_time: ~U[2026-06-18 16:00:00Z]
      })

      assert %CalendarEvent{transparency: :opaque} = normalised_for("evt-busy")
    end

    test "a repeating event carries it in its document" do
      DebugCalendarProvider.create_event(@client, %{
        uid: "evt-free-series",
        summary: "Gym",
        all_day: false,
        start_time: ~U[2026-06-15 07:00:00Z],
        end_time: ~U[2026-06-15 08:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
        transparency: "transparent"
      })

      assert %CalendarEvent{transparency: :transparent} =
               normalised_for("evt-free-series_20260615T070000")
    end
  end
end
