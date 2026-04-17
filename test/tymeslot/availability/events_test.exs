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

  describe "convert_events_to_timezone/3 — OAuth fresh-fetch plain maps" do
    # Plain maps from convert_events carry UTC start_time/end_time (no all_day/start_at/end_at).
    # This is the shape that caused the AvailabilityCache crash.
    test "converts a plain map event to the target timezone" do
      event = %{
        uid: "12tknqdsq0vh5ue9hqj5ak4ckp",
        summary: "Paul <> Luka",
        status: "confirmed",
        transparency: nil,
        start_time: ~U[2026-04-13 09:00:00Z],
        end_time: ~U[2026-04-13 10:00:00Z]
      }

      [converted] = Events.convert_events_to_timezone([event], "Etc/UTC", "Europe/London")

      assert %DateTime{} = converted.start_time
      assert %DateTime{} = converted.end_time
      assert converted.start_time.time_zone == "Europe/London"
      assert converted.end_time.time_zone == "Europe/London"
    end

    test "drops a plain map event with nil start_time" do
      event = %{
        uid: "x",
        status: "confirmed",
        start_time: nil,
        end_time: ~U[2026-04-13 10:00:00Z]
      }

      result = Events.convert_events_to_timezone([event], "Etc/UTC", "Europe/London")

      assert result == []
    end

    test "converts an all-day plain map event (Date values) anchored to the owner timezone" do
      # Google/Outlook emit Date values for all-day events in the plain-map
      # fresh-fetch path. The previous fix only handled DateTime values and
      # crashed the AvailabilityCache task with a function_clause on shift_safe.
      event = %{
        uid: "all-day-evt",
        summary: "Holiday",
        status: "confirmed",
        transparency: nil,
        start_time: ~D[2026-04-16],
        end_time: ~D[2026-04-17]
      }

      [converted] = Events.convert_events_to_timezone([event], "Europe/Tallinn", "Etc/UTC")

      assert %DateTime{} = converted.start_time
      assert %DateTime{} = converted.end_time
      assert converted.start_time.time_zone == "Etc/UTC"
      # Midnight in Tallinn (UTC+3 in April) == 21:00 UTC the previous day.
      assert converted.start_time == ~U[2026-04-15 21:00:00Z]
      assert converted.end_time == ~U[2026-04-16 21:00:00Z]
    end

    test "re-anchors UTC-midnight DateTime pair (Radicale/Zimbra all-day convention) to owner tz" do
      # Some CalDAV servers (Radicale, Zimbra) emit all-day events via the
      # fresh-fetch path as a pair of `DTSTART;VALUE=DATE-TIME` values at
      # UTC midnight — e.g. `20251015T000000Z` for "Oct 15 all day". The
      # iCal parser returns these as %DateTime{} at UTC midnight rather than
      # %Date{}, so the naïve zone-shift path would treat them as timed events
      # anchored to UTC midnight. For an owner in Pacific/Fiji (UTC+12) that
      # incorrectly blocks 12:00–12:00 next day in local time, shifting the
      # 24h block by half a day. Detect the pattern and anchor to owner-local
      # midnight instead.
      event = %{
        uid: "radicale-holiday",
        summary: "Fiji Day",
        status: "confirmed",
        transparency: nil,
        all_day: true,
        start_time: ~U[2025-10-15 00:00:00Z],
        end_time: ~U[2025-10-16 00:00:00Z]
      }

      [converted] = Events.convert_events_to_timezone([event], "Pacific/Fiji", "Etc/UTC")

      assert %DateTime{} = converted.start_time
      assert %DateTime{} = converted.end_time
      # Oct 15 00:00 Fiji (UTC+12) == Oct 14 12:00 UTC.
      # Oct 16 00:00 Fiji (UTC+12) == Oct 15 12:00 UTC.
      assert converted.start_time == ~U[2025-10-14 12:00:00Z]
      assert converted.end_time == ~U[2025-10-15 12:00:00Z]
    end

    test "leaves non-midnight UTC timed events alone (no false positive on midnight detection)" do
      # A genuine timed event at UTC midnight for a minute-long slot must NOT
      # trigger the all-day re-anchoring heuristic.
      event = %{
        uid: "timed-midnight",
        summary: "Server restart",
        status: "confirmed",
        transparency: nil,
        start_time: ~U[2025-10-15 00:00:00Z],
        end_time: ~U[2025-10-15 00:01:00Z]
      }

      [converted] = Events.convert_events_to_timezone([event], "Pacific/Fiji", "Etc/UTC")

      assert converted.start_time == ~U[2025-10-15 00:00:00Z]
      assert converted.end_time == ~U[2025-10-15 00:01:00Z]
    end

    test "genuine 24h UTC-midnight timed event (all_day absent) is NOT re-anchored" do
      # A legitimate timed event that happens to run exactly 00:00Z → 00:00Z
      # the next day (e.g. a 24-hour maintenance window) must pass through as
      # a timed event. Without `all_day: true` the re-anchoring heuristic must
      # not fire, even though both endpoints are UTC midnight.
      event = %{
        uid: "maintenance-window",
        summary: "24h maintenance",
        status: "confirmed",
        start_time: ~U[2025-10-15 00:00:00Z],
        end_time: ~U[2025-10-16 00:00:00Z]
      }

      [converted] = Events.convert_events_to_timezone([event], "Pacific/Fiji", "Etc/UTC")

      # No re-anchoring: times pass through as-is (already in Etc/UTC).
      assert converted.start_time == ~U[2025-10-15 00:00:00Z]
      assert converted.end_time == ~U[2025-10-16 00:00:00Z]
    end

    test "genuine 48h UTC-midnight timed event (all_day: false) is NOT re-anchored" do
      # Same as above but spanning two days, with explicit all_day: false.
      event = %{
        uid: "maintenance-48h",
        summary: "48h maintenance",
        status: "confirmed",
        all_day: false,
        start_time: ~U[2025-10-15 00:00:00Z],
        end_time: ~U[2025-10-17 00:00:00Z]
      }

      [converted] = Events.convert_events_to_timezone([event], "Pacific/Fiji", "Etc/UTC")

      assert converted.start_time == ~U[2025-10-15 00:00:00Z]
      assert converted.end_time == ~U[2025-10-17 00:00:00Z]
    end

    test "Radicale-style all-day plain map (all_day: true) IS re-anchored to owner-local midnight" do
      # When a provider explicitly marks a plain-map event as all_day: true with
      # UTC-midnight DateTimes (Radicale/Zimbra convention), it must be re-anchored
      # to the owner's local midnight.
      event = %{
        uid: "radicale-fiji-day",
        summary: "Fiji Day (explicit all_day)",
        status: "confirmed",
        all_day: true,
        start_time: ~U[2025-10-15 00:00:00Z],
        end_time: ~U[2025-10-16 00:00:00Z]
      }

      [converted] = Events.convert_events_to_timezone([event], "Pacific/Fiji", "Etc/UTC")

      # Oct 15 00:00 Fiji (UTC+12) == Oct 14 12:00 UTC.
      # Oct 16 00:00 Fiji (UTC+12) == Oct 15 12:00 UTC.
      assert converted.start_time == ~U[2025-10-14 12:00:00Z]
      assert converted.end_time == ~U[2025-10-15 12:00:00Z]
    end

    test "Radicale-style 48h all-day plain map (all_day: true) IS re-anchored to owner-local midnight" do
      # Multi-day variant: two-day all-day event via the UTC-midnight convention.
      event = %{
        uid: "radicale-fiji-2day",
        summary: "Two-day event",
        status: "confirmed",
        all_day: true,
        start_time: ~U[2025-10-15 00:00:00Z],
        end_time: ~U[2025-10-17 00:00:00Z]
      }

      [converted] = Events.convert_events_to_timezone([event], "Pacific/Fiji", "Etc/UTC")

      assert converted.start_time == ~U[2025-10-14 12:00:00Z]
      assert converted.end_time == ~U[2025-10-16 12:00:00Z]
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
