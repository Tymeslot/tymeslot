defmodule Tymeslot.Availability.EventsTest do
  @moduledoc """
  Tests for the Events module - event processing and timezone conversion.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.Events
  alias Tymeslot.Integrations.Calendar.CalendarEvent

  defp timed_event(start_at, end_at, opts \\ []) do
    uid = Keyword.get(opts, :uid, "evt-#{System.unique_integer([:positive])}")

    CalendarEvent.new!(%{
      uid: uid,
      calendar_integration_id: 1,
      provider: :google,
      provider_calendar_id: "primary",
      provider_event_id: uid,
      all_day: false,
      start_at: start_at,
      end_at: end_at,
      synced_at: DateTime.utc_now()
    })
  end

  defp all_day_event(start_date, end_date, opts \\ []) do
    uid = Keyword.get(opts, :uid, "evt-#{System.unique_integer([:positive])}")

    CalendarEvent.new!(%{
      uid: uid,
      calendar_integration_id: 1,
      provider: :google,
      provider_calendar_id: "primary",
      provider_event_id: uid,
      all_day: true,
      start_date: start_date,
      end_date: end_date,
      synced_at: DateTime.utc_now()
    })
  end

  describe "convert_events_to_timezone/3 — timed events" do
    test "converts events from UTC to Eastern timezone" do
      events = [timed_event(~U[2025-06-15 14:00:00Z], ~U[2025-06-15 15:00:00Z])]

      converted = Events.convert_events_to_timezone(events, "Etc/UTC", "America/New_York")

      assert length(converted) == 1
      event = hd(converted)
      # UTC 14:00 = Eastern 10:00 AM (during EDT)
      assert event.start_time.time_zone == "America/New_York"
      assert event.end_time.time_zone == "America/New_York"
    end

    test "converts multiple events" do
      events = [
        timed_event(~U[2025-06-15 10:00:00Z], ~U[2025-06-15 11:00:00Z]),
        timed_event(~U[2025-06-15 14:00:00Z], ~U[2025-06-15 15:00:00Z])
      ]

      converted = Events.convert_events_to_timezone(events, "Etc/UTC", "Europe/London")

      assert length(converted) == 2

      for event <- converted do
        assert event.start_time.time_zone == "Europe/London"
        assert event.end_time.time_zone == "Europe/London"
      end
    end

    test "handles empty events list" do
      assert Events.convert_events_to_timezone([], "Etc/UTC", "America/New_York") == []
    end

    test "returns maps with start_time and end_time keys" do
      events = [timed_event(~U[2025-06-15 14:00:00Z], ~U[2025-06-15 15:00:00Z])]

      [converted] = Events.convert_events_to_timezone(events, "Etc/UTC", "America/New_York")

      assert Map.has_key?(converted, :start_time)
      assert Map.has_key?(converted, :end_time)
      assert %DateTime{} = converted.start_time
      assert %DateTime{} = converted.end_time
    end
  end

  describe "convert_events_to_timezone/3 — all-day events" do
    test "anchors all-day event dates to midnight in the owner's timezone" do
      events = [all_day_event(~D[2025-06-15], ~D[2025-06-16])]

      # Owner is in New York, user is in UTC
      # June 15th 00:00:00 EDT = June 15th 04:00:00 UTC
      converted = Events.convert_events_to_timezone(events, "America/New_York", "Etc/UTC")

      assert length(converted) == 1
      event = hd(converted)
      assert %DateTime{} = event.start_time
      assert %DateTime{} = event.end_time
      assert event.start_time.time_zone == "Etc/UTC"
      assert event.start_time.day == 15
      assert event.start_time.hour == 4
      assert event.start_time.minute == 0
    end

    test "all-day event in UTC stays at midnight boundaries when viewed in UTC" do
      events = [all_day_event(~D[2025-06-15], ~D[2025-06-16])]

      converted = Events.convert_events_to_timezone(events, "Etc/UTC", "Etc/UTC")

      assert length(converted) == 1
      event = hd(converted)
      assert event.start_time == ~U[2025-06-15 00:00:00Z]
      assert event.end_time == ~U[2025-06-16 00:00:00Z]
    end

    test "all-day event spans correctly when shifted to a later timezone" do
      events = [all_day_event(~D[2025-06-15], ~D[2025-06-16])]

      # Owner in UTC, user in Tokyo (UTC+9)
      converted = Events.convert_events_to_timezone(events, "Etc/UTC", "Asia/Tokyo")

      event = hd(converted)
      # Midnight UTC = 09:00 JST
      assert event.start_time.hour == 9
      assert event.start_time.day == 15
      assert event.end_time.hour == 9
      assert event.end_time.day == 16
    end
  end
end
