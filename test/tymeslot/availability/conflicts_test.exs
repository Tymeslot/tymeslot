defmodule Tymeslot.Availability.ConflictsTest do
  @moduledoc """
  Unit tests for `Conflicts.date_has_slots_with_events?/6` covering the
  boolean month-view check, advance-booking window enforcement, and a
  small performance budget.

  Cross-cutting property-based tests (timezone, DST, all-day boundary,
  and pre-filtering coverage) live in `Tymeslot.Availability.ConflictsPropertyTest`.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  alias Tymeslot.Availability.{BusinessHours, Conflicts, Events}
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Utils.DateTimeUtils

  defp get_future_weekday do
    date = Date.add(Date.utc_today(), 7)

    case Date.day_of_week(date) do
      6 -> Date.add(date, 2)
      7 -> Date.add(date, 1)
      _weekday -> date
    end
  end

  # Builds a lightweight map with start_time/end_time for tests that call
  # Conflicts functions directly (which expect pre-converted maps).
  defp build_conflict_map(date, start_time, end_time, timezone \\ "Etc/UTC") do
    %{
      start_time: DateTime.new!(date, start_time, timezone),
      end_time: DateTime.new!(date, end_time, timezone)
    }
  end

  describe "date_has_slots_with_events?/6" do
    test "returns true when no events block the day" do
      date = get_future_weekday()

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          [],
          DateTime.utc_now(),
          %{}
        )

      assert result == true
    end

    test "returns true when events don't cover entire business hours" do
      date = get_future_weekday()

      events = [build_conflict_map(date, ~T[10:00:00], ~T[11:00:00])]

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          events,
          DateTime.utc_now(),
          %{buffer_minutes: 0}
        )

      assert result == true
    end

    test "returns false when event covers entire business hours" do
      date = Date.add(Date.utc_today(), 7)

      events = [build_conflict_map(date, ~T[00:00:00], ~T[23:59:59])]

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          events,
          DateTime.utc_now(),
          %{buffer_minutes: 0}
        )

      assert result == false
    end

    test "handles different timezones" do
      date = get_future_weekday()

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "America/New_York",
          "Europe/London",
          [],
          DateTimeUtils.now_in_timezone("Europe/London"),
          %{}
        )

      assert result == true
    end

    test "transparent events are filtered upstream via CalendarEvent.blocking?/1" do
      date = get_future_weekday()

      # A full-day blocking event would block everything, but when transparent
      # it gets filtered out by CalendarEvent.blocking?/1 before reaching Conflicts.
      event =
        CalendarEvent.new!(%{
          uid: "transparent-full-day",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "transparent-full-day",
          provider_calendar_id: "primary",
          all_day: false,
          start_at: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
          end_at: DateTime.new!(date, ~T[23:59:59], "Etc/UTC"),
          synced_at: DateTime.utc_now(),
          transparency: :transparent
        })

      blocking = Enum.filter([event], &CalendarEvent.blocking?/1)
      events_in_tz = Events.convert_events_to_timezone(blocking, "Etc/UTC", "Etc/UTC")

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          events_in_tz,
          DateTime.utc_now(),
          %{buffer_minutes: 0}
        )

      assert result == true
    end

    test "returns false for today if current time is after business hours" do
      # 14 hours ahead of UTC
      user_tz = "Etc/GMT-14"
      now_in_tz = DateTime.shift_zone!(DateTime.utc_now(), user_tz)
      today_in_tz = DateTime.to_date(now_in_tz)

      # Business hours end at 19:30 (default)
      # If now_in_tz is after 19:30, it should be false.
      if now_in_tz.hour >= 20 do
        result =
          Conflicts.date_has_slots_with_events?(
            today_in_tz,
            "Etc/UTC",
            user_tz,
            [],
            DateTimeUtils.now_in_timezone(user_tz),
            %{min_advance_hours: 0}
          )

        assert result == false,
               "Should be unavailable when business hours have passed "
      end
    end

    test "returns true for today if current time is before business hours end" do
      # 12 hours behind UTC
      user_tz = "Etc/GMT+12"
      now_in_tz = DateTime.shift_zone!(DateTime.utc_now(), user_tz)
      today_in_tz = DateTime.to_date(now_in_tz)

      # If it's early morning in this timezone, and business hours end at 17:00, it should be true.
      # BUT ONLY if today is a business day!
      if now_in_tz.hour < 14 and BusinessHours.business_day?(today_in_tz, nil) do
        result =
          Conflicts.date_has_slots_with_events?(
            today_in_tz,
            "Etc/UTC",
            user_tz,
            [],
            now_in_tz,
            %{min_advance_hours: 0}
          )

        assert result == true, "Should be available when business hours are still in the future"
      end
    end

    test "date_has_slots_with_events? handles all-day CalendarEvent without crashing" do
      date = get_future_weekday()

      event =
        CalendarEvent.new!(%{
          uid: "all-day-block",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "all-day-block",
          provider_calendar_id: "primary",
          all_day: true,
          start_date: date,
          end_date: Date.add(date, 1),
          synced_at: DateTime.utc_now()
        })

      events_in_tz = Events.convert_events_to_timezone([event], "Etc/UTC", "Etc/UTC")

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          events_in_tz,
          DateTime.utc_now(),
          %{buffer_minutes: 0, min_advance_hours: 0}
        )

      # All-day event covers 00:00–00:00 next day, should block the entire day
      assert result == false
    end
  end

  describe "max_advance_booking_days enforcement" do
    # Pin `now` to a fixed past date so these tests never depend on wall-clock time.
    # now = 2026-01-01 09:00:00Z

    test "returns false when date is beyond max_advance_booking_days" do
      # Window: now + 1 day = 2026-01-02 09:00:00Z
      # Slots on 2026-01-05 (Monday) start at 11:00 UTC at the earliest,
      # which is past the window end → within_booking_window? rejects them.
      now = ~U[2026-01-01 09:00:00Z]
      date = ~D[2026-01-05]

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          [],
          now,
          %{max_advance_booking_days: 1, min_advance_hours: 0}
        )

      assert result == false,
             "Expected no bookable slots when date is beyond the 1-day booking window"
    end

    test "returns true when date is within max_advance_booking_days" do
      # Window: now + 2 days = 2026-01-03 09:00:00Z
      # Slots on 2026-01-02 (Friday) start at 11:00 UTC, which is before the
      # window end → within_booking_window? admits them.
      now = ~U[2026-01-01 09:00:00Z]
      date = ~D[2026-01-02]

      result =
        Conflicts.date_has_slots_with_events?(
          date,
          "Etc/UTC",
          "Etc/UTC",
          [],
          now,
          %{max_advance_booking_days: 2, min_advance_hours: 0}
        )

      assert result == true,
             "Expected bookable slots when date is within the 2-day booking window"
    end
  end

  describe "performance" do
    test "date_has_slots_with_events? remains fast with a noisy calendar (500+ events)" do
      date = ~D[2026-06-15]
      timezone = "UTC"

      events =
        Enum.map(1..500, fn i ->
          day = rem(i, 28) + 1
          hour = rem(i, 24)
          start_dt = DateTime.new!(Date.new!(2026, 6, day), Time.new!(hour, 0, 0), timezone)
          end_dt = DateTime.add(start_dt, 30, :minute)
          %{start_time: start_dt, end_time: end_dt}
        end)

      config = %{buffer_minutes: 15, min_advance_hours: 0}

      {micro, result} =
        :timer.tc(fn ->
          Conflicts.date_has_slots_with_events?(
            date,
            timezone,
            timezone,
            events,
            DateTimeUtils.now_in_timezone(timezone),
            config
          )
        end)

      # Ensure it's reasonably fast (under 50ms for a single day check even with 500 events)
      # Usually this should be < 15ms on modern hardware, but we allow 50ms for slower CI.
      assert micro < 50_000
      assert is_boolean(result)
    end
  end
end
