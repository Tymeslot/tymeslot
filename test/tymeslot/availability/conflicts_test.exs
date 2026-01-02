defmodule Tymeslot.Availability.ConflictsTest do
  @moduledoc """
  Tests for the Conflicts module - conflict detection and slot filtering.
  """

  use ExUnit.Case, async: true

  alias Tymeslot.Availability.Conflicts

  describe "convert_events_to_timezone/2" do
    test "converts events from UTC to Eastern timezone" do
      events = [
        %{
          start_time: ~U[2025-06-15 14:00:00Z],
          end_time: ~U[2025-06-15 15:00:00Z]
        }
      ]

      converted = Conflicts.convert_events_to_timezone(events, "America/New_York")

      assert length(converted) == 1
      event = hd(converted)
      # UTC 14:00 = Eastern 10:00 AM (during EDT)
      assert event.start_time.time_zone == "America/New_York"
      assert event.end_time.time_zone == "America/New_York"
    end

    test "converts multiple events" do
      events = [
        %{
          start_time: ~U[2025-06-15 10:00:00Z],
          end_time: ~U[2025-06-15 11:00:00Z]
        },
        %{
          start_time: ~U[2025-06-15 14:00:00Z],
          end_time: ~U[2025-06-15 15:00:00Z]
        }
      ]

      converted = Conflicts.convert_events_to_timezone(events, "Europe/London")

      assert length(converted) == 2

      for event <- converted do
        assert event.start_time.time_zone == "Europe/London"
        assert event.end_time.time_zone == "Europe/London"
      end
    end

    test "handles empty events list" do
      assert Conflicts.convert_events_to_timezone([], "America/New_York") == []
    end

    test "preserves other event fields" do
      events = [
        %{
          start_time: ~U[2025-06-15 14:00:00Z],
          end_time: ~U[2025-06-15 15:00:00Z],
          title: "Test Meeting",
          uid: "test-uid-123"
        }
      ]

      converted = Conflicts.convert_events_to_timezone(events, "America/New_York")

      event = hd(converted)
      assert event.title == "Test Meeting"
      assert event.uid == "test-uid-123"
    end
  end

  describe "filter_available_slots/6 - basic filtering" do
    test "returns all slots when no events" do
      slots = ["9:00 AM", "9:30 AM", "10:00 AM", "10:30 AM"]
      events = []
      date = Date.add(Date.utc_today(), 7)

      result = filter_slots(slots, events, %{date: date})

      assert length(result) == 4
    end

    test "filters out slots that conflict with events" do
      result = conflict_slots()

      # 10:00 AM should be filtered out due to direct conflict
      refute "10:00 AM" in result
      assert "9:00 AM" in result
      assert "9:30 AM" in result
      assert "10:30 AM" in result
      assert "11:00 AM" in result
    end

    test "respects buffer minutes when filtering" do
      result = conflict_slots(30)

      # With 30 min buffer: 9:30, 10:00, and 10:30 should be filtered
      refute "9:30 AM" in result
      refute "10:00 AM" in result
      refute "10:30 AM" in result
      assert "9:00 AM" in result
      assert "11:00 AM" in result
    end

    test "filters slots in the past based on advance booking hours" do
      # Using a date very far in the future to avoid min_advance_hours conflicts
      date = Date.add(Date.utc_today(), 30)
      slots = ["9:00 AM", "10:00 AM", "11:00 AM"]
      events = []

      result = filter_slots(slots, events, %{date: date, min_advance_hours: 3})

      # All slots should be available since date is far in future
      assert length(result) == 3
    end

    test "filters slots beyond max advance booking days" do
      # Date far in the future (beyond max)
      date = Date.add(Date.utc_today(), 100)
      slots = ["9:00 AM", "10:00 AM", "11:00 AM"]
      events = []

      result = filter_slots(slots, events, %{date: date, max_advance_booking_days: 30})

      # All slots should be filtered out - beyond max booking window
      assert result == []
    end
  end

  describe "filter_available_slots/6 - edge cases" do
    test "handles empty slots list" do
      events = []
      date = Date.add(Date.utc_today(), 7)

      result = filter_slots([], events, %{date: date})

      assert result == []
    end

    test "handles multiple conflicting events" do
      slots = ["9:00 AM", "10:00 AM", "11:00 AM", "12:00 PM", "1:00 PM"]
      date = Date.add(Date.utc_today(), 7)

      # Two separate events
      events = [
        %{
          start_time: DateTime.new!(date, ~T[10:00:00], "Etc/UTC"),
          end_time: DateTime.new!(date, ~T[10:30:00], "Etc/UTC")
        },
        %{
          start_time: DateTime.new!(date, ~T[12:00:00], "Etc/UTC"),
          end_time: DateTime.new!(date, ~T[12:30:00], "Etc/UTC")
        }
      ]

      result = filter_slots(slots, events, %{date: date})

      refute "10:00 AM" in result
      refute "12:00 PM" in result
      assert "9:00 AM" in result
      assert "11:00 AM" in result
      assert "1:00 PM" in result
    end

    test "handles different duration values" do
      slots = ["9:00 AM", "9:30 AM", "10:00 AM", "10:30 AM"]
      date = Date.add(Date.utc_today(), 7)

      # Event at 10:00-10:30
      events = [
        %{
          start_time: DateTime.new!(date, ~T[10:00:00], "Etc/UTC"),
          end_time: DateTime.new!(date, ~T[10:30:00], "Etc/UTC")
        }
      ]

      # 60-minute slots starting at 9:30 would end at 10:30, overlapping with event
      result = filter_slots(slots, events, %{date: date, duration: 60})

      # 9:30 AM slot (60 min = 9:30-10:30) overlaps with 10:00-10:30 event
      refute "9:30 AM" in result
      # 10:00 AM slot (60 min = 10:00-11:00) overlaps with 10:00-10:30 event
      refute "10:00 AM" in result
      # 9:00 AM slot (60 min = 9:00-10:00) does NOT overlap - it ends exactly when event starts
      assert "9:00 AM" in result
      # 10:30 AM slot (60 min = 10:30-11:30) does NOT overlap - it starts when event ends
      assert "10:30 AM" in result
    end
  end

  describe "date_has_slots_with_events?/5" do
    test "returns true when no events block the day" do
      date = Date.add(Date.utc_today(), 7)

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          [],
          %{}
        )

      assert result == true
    end

    test "returns true when events don't cover entire business hours" do
      date = Date.add(Date.utc_today(), 7)

      # Event only covers part of the day
      events = [
        %{
          start_time: DateTime.new!(date, ~T[10:00:00], "Etc/UTC"),
          end_time: DateTime.new!(date, ~T[11:00:00], "Etc/UTC")
        }
      ]

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          events,
          %{buffer_minutes: 0}
        )

      assert result == true
    end

    test "returns false when event covers entire business hours" do
      date = Date.add(Date.utc_today(), 7)

      # Event covers the entire business day (starts before 9am, ends after 5pm)
      # The function checks if buffered event start <= business start AND buffered event end >= business end
      events = [
        %{
          start_time: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
          end_time: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
        }
      ]

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          events,
          %{buffer_minutes: 0}
        )

      assert result == false
    end

    test "handles different timezones" do
      date = Date.add(Date.utc_today(), 7)

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "America/New_York",
          "Europe/London",
          [],
          %{}
        )

      assert result == true
    end
  end

  describe "events_overlap?/4" do
    test "returns true when events overlap" do
      slot_start = ~U[2025-06-15 10:00:00Z]
      slot_end = ~U[2025-06-15 11:00:00Z]
      event_start = ~U[2025-06-15 10:30:00Z]
      event_end = ~U[2025-06-15 11:30:00Z]

      assert Conflicts.events_overlap?(slot_start, slot_end, event_start, event_end)
    end

    test "returns false when events don't overlap" do
      slot_start = ~U[2025-06-15 10:00:00Z]
      slot_end = ~U[2025-06-15 11:00:00Z]
      event_start = ~U[2025-06-15 12:00:00Z]
      event_end = ~U[2025-06-15 13:00:00Z]

      refute Conflicts.events_overlap?(slot_start, slot_end, event_start, event_end)
    end

    test "returns false when events are adjacent (slot ends when event starts)" do
      slot_start = ~U[2025-06-15 10:00:00Z]
      slot_end = ~U[2025-06-15 11:00:00Z]
      event_start = ~U[2025-06-15 11:00:00Z]
      event_end = ~U[2025-06-15 12:00:00Z]

      refute Conflicts.events_overlap?(slot_start, slot_end, event_start, event_end)
    end

    test "returns false when events are adjacent (event ends when slot starts)" do
      slot_start = ~U[2025-06-15 11:00:00Z]
      slot_end = ~U[2025-06-15 12:00:00Z]
      event_start = ~U[2025-06-15 10:00:00Z]
      event_end = ~U[2025-06-15 11:00:00Z]

      refute Conflicts.events_overlap?(slot_start, slot_end, event_start, event_end)
    end

    test "returns true when slot is completely inside event" do
      slot_start = ~U[2025-06-15 10:30:00Z]
      slot_end = ~U[2025-06-15 11:30:00Z]
      event_start = ~U[2025-06-15 10:00:00Z]
      event_end = ~U[2025-06-15 12:00:00Z]

      assert Conflicts.events_overlap?(slot_start, slot_end, event_start, event_end)
    end

    test "returns true when event is completely inside slot" do
      slot_start = ~U[2025-06-15 10:00:00Z]
      slot_end = ~U[2025-06-15 12:00:00Z]
      event_start = ~U[2025-06-15 10:30:00Z]
      event_end = ~U[2025-06-15 11:30:00Z]

      assert Conflicts.events_overlap?(slot_start, slot_end, event_start, event_end)
    end
  end

  defp build_events(date, start_time, end_time, timezone \\ "Etc/UTC") do
    [
      %{
        start_time: DateTime.new!(date, start_time, timezone),
        end_time: DateTime.new!(date, end_time, timezone)
      }
    ]
  end

  defp conflict_slots(buffer_minutes \\ 0) do
    slots = ["9:00 AM", "9:30 AM", "10:00 AM", "10:30 AM", "11:00 AM"]
    date = Date.add(Date.utc_today(), 7)
    events = build_events(date, ~T[10:00:00], ~T[10:30:00])
    filter_slots(slots, events, %{date: date, buffer_minutes: buffer_minutes})
  end

  defp filter_slots(slots, events, overrides) do
    duration = Map.get(overrides, :duration, 30)
    timezone = Map.get(overrides, :timezone, "Etc/UTC")
    date = Map.get(overrides, :date, Date.add(Date.utc_today(), 7))

    Conflicts.filter_available_slots(
      slots,
      events,
      duration,
      timezone,
      date,
      filter_opts(Map.drop(overrides, [:duration, :timezone, :date]))
    )
  end

  defp filter_opts(overrides) do
    Map.merge(%{min_advance_hours: 0, max_advance_booking_days: 90, buffer_minutes: 0}, overrides)
  end
end
