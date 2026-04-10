defmodule Tymeslot.Availability.FilterAvailableSlotsTest do
  @moduledoc """
  Tests for Conflicts.filter_available_slots/6 — slot conflict detection and filtering.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.{Conflicts, Events}
  alias Tymeslot.Integrations.Calendar.CalendarEvent

  # Builds a timed CalendarEvent struct for use in tests that go through
  # the full pipeline (which expects CalendarEvent structs).
  defp build_calendar_event(date, start_time, end_time, timezone \\ "Etc/UTC", opts \\ []) do
    uid = Keyword.get(opts, :uid, "test-#{System.unique_integer([:positive])}")

    CalendarEvent.new!(%{
      uid: uid,
      calendar_integration_id: 1,
      provider: :google,
      provider_calendar_id: "primary",
      provider_event_id: uid,
      all_day: false,
      start_at: DateTime.new!(date, start_time, timezone),
      end_at: DateTime.new!(date, end_time, timezone),
      synced_at: DateTime.utc_now(),
      transparency: Keyword.get(opts, :transparency, :opaque),
      status: Keyword.get(opts, :status, :confirmed)
    })
  end

  # Builds a lightweight map with start_time/end_time for tests that call
  # Conflicts functions directly (which expect pre-converted maps).
  defp build_conflict_map(date, start_time, end_time, timezone \\ "Etc/UTC") do
    %{
      start_time: DateTime.new!(date, start_time, timezone),
      end_time: DateTime.new!(date, end_time, timezone)
    }
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

  describe "filter_available_slots/6 - transparency via CalendarEvent.blocking?/1" do
    setup do
      date = Date.add(Date.utc_today(), 7)
      slots = ["9:00 AM", "10:00 AM", "11:00 AM"]
      %{date: date, slots: slots}
    end

    test "transparent events are excluded by CalendarEvent.blocking?/1", %{
      date: date,
      slots: slots
    } do
      event =
        build_calendar_event(date, ~T[10:00:00], ~T[10:30:00], "Etc/UTC",
          transparency: :transparent
        )

      refute CalendarEvent.blocking?(event)

      # When passed through the full pipeline, transparent events don't block
      blocking = Enum.filter([event], &CalendarEvent.blocking?/1)
      events_in_tz = Events.convert_events_to_timezone(blocking, "Etc/UTC", "Etc/UTC")
      result = filter_slots(slots, events_in_tz, %{date: date})

      assert "9:00 AM" in result
      assert "10:00 AM" in result
      assert "11:00 AM" in result
    end

    test "opaque events block slots", %{date: date, slots: slots} do
      event =
        build_calendar_event(date, ~T[10:00:00], ~T[10:30:00], "Etc/UTC", transparency: :opaque)

      assert CalendarEvent.blocking?(event)

      blocking = Enum.filter([event], &CalendarEvent.blocking?/1)
      events_in_tz = Events.convert_events_to_timezone(blocking, "Etc/UTC", "Etc/UTC")
      result = filter_slots(slots, events_in_tz, %{date: date})

      refute "10:00 AM" in result
      assert "9:00 AM" in result
      assert "11:00 AM" in result
    end

    test "cancelled events are excluded by CalendarEvent.blocking?/1", %{
      date: date,
      slots: slots
    } do
      event =
        build_calendar_event(date, ~T[10:00:00], ~T[10:30:00], "Etc/UTC", status: :cancelled)

      refute CalendarEvent.blocking?(event)

      blocking = Enum.filter([event], &CalendarEvent.blocking?/1)
      events_in_tz = Events.convert_events_to_timezone(blocking, "Etc/UTC", "Etc/UTC")
      result = filter_slots(slots, events_in_tz, %{date: date})

      assert length(result) == 3
    end

    test "declined events are excluded by CalendarEvent.blocking?/1", %{
      date: date,
      slots: slots
    } do
      event = build_calendar_event(date, ~T[10:00:00], ~T[10:30:00], "Etc/UTC", status: :declined)

      refute CalendarEvent.blocking?(event)

      blocking = Enum.filter([event], &CalendarEvent.blocking?/1)
      events_in_tz = Events.convert_events_to_timezone(blocking, "Etc/UTC", "Etc/UTC")
      result = filter_slots(slots, events_in_tz, %{date: date})

      assert length(result) == 3
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

      # Two separate events (pre-converted maps)
      events = [
        build_conflict_map(date, ~T[10:00:00], ~T[10:30:00]),
        build_conflict_map(date, ~T[12:00:00], ~T[12:30:00])
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
      events = [build_conflict_map(date, ~T[10:00:00], ~T[10:30:00])]

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

  describe "all-day events with CalendarEvent structs" do
    test "filter_available_slots blocks slots when all-day event covers the date" do
      date = Date.add(Date.utc_today(), 7)
      slots = ["9:00 AM", "10:00 AM", "11:00 AM"]

      # All-day event as CalendarEvent, converted through Events
      event =
        CalendarEvent.new!(%{
          uid: "all-day-test",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "all-day-test",
          provider_calendar_id: "primary",
          all_day: true,
          start_date: date,
          end_date: Date.add(date, 1),
          synced_at: DateTime.utc_now()
        })

      events_in_tz = Events.convert_events_to_timezone([event], "Etc/UTC", "Etc/UTC")

      result = filter_slots(slots, events_in_tz, %{date: date})

      assert result == [], "All slots should be blocked by an all-day event"
    end

    test "filter_available_slots handles mixed all-day and timed CalendarEvents" do
      date = Date.add(Date.utc_today(), 7)
      slots = ["9:00 AM", "2:00 PM"]

      all_day =
        CalendarEvent.new!(%{
          uid: "all-day-mixed",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "all-day-mixed",
          provider_calendar_id: "primary",
          all_day: true,
          start_date: date,
          end_date: Date.add(date, 1),
          synced_at: DateTime.utc_now()
        })

      timed = build_calendar_event(date, ~T[14:00:00], ~T[15:00:00])

      events_in_tz =
        Events.convert_events_to_timezone([all_day, timed], "Etc/UTC", "Etc/UTC")

      result = filter_slots(slots, events_in_tz, %{date: date})

      assert result == [], "Both all-day and timed events should block their respective slots"
    end
  end

  defp conflict_slots(buffer_minutes \\ 0) do
    slots = ["9:00 AM", "9:30 AM", "10:00 AM", "10:30 AM", "11:00 AM"]
    date = Date.add(Date.utc_today(), 7)
    events = [build_conflict_map(date, ~T[10:00:00], ~T[10:30:00])]
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
