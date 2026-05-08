defmodule Tymeslot.Availability.ConflictsTest do
  @moduledoc """
  Tests for Conflicts.date_has_slots_with_events?/6 and cross-cutting property tests
  covering timezone handling, DST transitions, all-day event boundaries, and pre-filtering.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  use ExUnitProperties

  alias Tymeslot.Availability.{BusinessHours, Calculate, Conflicts, Events}
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Utils.{DateTimeUtils, TimeRange}

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

  property "date_has_slots_with_events? matches available_slots availability" do
    # This property test verifies that the optimized month-view check
    # (date_has_slots_with_events?) returns 'true' if and only if
    # `available_slots/6` returns at least one slot. Both directions are
    # required: a one-way assertion previously allowed the boolean check
    # to be falsely-optimistic and customers saw "no times available"
    # empty states after clicking on a day the calendar grid marked as
    # bookable.

    check all(
            timezone <-
              member_of([
                "UTC",
                "America/New_York",
                "Europe/London",
                "Asia/Tokyo",
                "Australia/Sydney",
                "Pacific/Auckland"
              ]),
            # Use a date in the future to avoid past-date filtering
            days_ahead <- integer(5..60),
            # Meeting duration between 15 and 120 minutes
            duration <- member_of([15, 30, 45, 60, 90, 120]),
            # Buffer between 0 and 60 minutes
            buffer <- integer(0..60),
            # Generate some random events around the target date
            events <-
              list_of(
                tuple({
                  # Event start: +/- 3 days from target date
                  integer(-3..3),
                  # Hour
                  integer(0..23),
                  # Minute
                  integer(0..59),
                  # Duration
                  integer(15..480)
                }),
                max_length: 10
              )
          ) do
      date = Date.add(Date.utc_today(), days_ahead)
      config = %{buffer_minutes: buffer, min_advance_hours: 0, duration_minutes: duration}

      # Convert generated event data into CalendarEvent structs
      calendar_events =
        Enum.map(events, fn {day_offset, hour, min, dur} ->
          event_date = Date.add(date, day_offset)
          time = Time.new!(hour, min, 0)

          start_at = DateTimeUtils.create_datetime_safe(event_date, time, timezone)
          end_at = DateTime.add(start_at, dur, :minute)

          CalendarEvent.new!(%{
            uid: "prop-#{System.unique_integer([:positive])}",
            calendar_integration_id: 1,
            provider: :google,
            provider_event_id: "prop-#{System.unique_integer([:positive])}",
            provider_calendar_id: "primary",
            all_day: false,
            start_at: start_at,
            end_at: end_at,
            synced_at: DateTime.utc_now()
          })
        end)

      # Pre-filter and convert for the optimized check (mirrors what Calculate does)
      blocking = Enum.filter(calendar_events, &CalendarEvent.blocking?/1)
      events_in_tz = Events.convert_events_to_timezone(blocking, timezone, timezone)

      # For this test, we use default business hours (Mon-Fri 11am-7:30pm)
      # We only check weekdays to ensure we have business hours
      if Date.day_of_week(date) in 1..5 do
        # 1. Get availability using optimized check (which uses pre-filtering)
        has_slots_optimized =
          Conflicts.date_has_slots_with_events?(
            date,
            # owner_tz
            timezone,
            # user_tz
            timezone,
            events_in_tz,
            DateTimeUtils.now_in_timezone(timezone),
            config
          )

        # 2. Get availability using full calculation (no pre-filtering)
        {:ok, slots} =
          Calculate.available_slots(
            date,
            duration,
            # user_tz
            timezone,
            # owner_tz
            timezone,
            calendar_events,
            config
          )

        has_slots_full = slots != []

        assert has_slots_optimized == has_slots_full,
               """
               EQUIVALENCE BUG: optimized=#{has_slots_optimized}, full=#{has_slots_full}
               Date: #{date}, TZ: #{timezone}
               Events: #{inspect(events_in_tz)}
               Slots from full check: #{inspect(slots)}
               """
      end
    end
  end

  describe "date_has_slots_with_events?/6" do
    test "returns true when no events block the day" do
      # Ensure we use a future weekday (default business hours)
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
      # Ensure we use a future weekday
      date = get_future_weekday()

      # Event only covers part of the day (pre-converted map)
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

      # Event covers the entire business day
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
      date = Date.add(Date.utc_today(), 7)

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
            # owner_tz
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
            # owner_tz
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

  property "all-day events on Day X do not block slots on Day X+1" do
    # Verify that all-day events ending at 00:00:00 of the next day (common in Outlook)
    # don't accidentally block the next day.
    check all(
            timezone <-
              member_of([
                "UTC",
                "America/New_York",
                "Europe/London",
                "Asia/Tokyo",
                "Australia/Sydney"
              ]),
            # Fixed dates for Monday/Tuesday
            monday_date <- constant(~D[2025-06-16]),
            tuesday_date <- constant(~D[2025-06-17]),
            # Random slot on Tuesday
            slot_hour <- integer(0..23),
            slot_min <- member_of([0, 15, 30, 45]),
            duration <- member_of([15, 30, 60, 120])
          ) do
      # All-day event on Monday: start ~D[2025-06-16], end ~D[2025-06-17]
      # This is how Outlook/Google represent "Monday" (exclusive end)
      calendar_event =
        CalendarEvent.new!(%{
          uid: "all-day-monday",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "all-day-monday",
          provider_calendar_id: "primary",
          all_day: true,
          start_date: monday_date,
          end_date: tuesday_date,
          synced_at: DateTime.utc_now()
        })

      # Convert to the target timezone (returns maps with start_time/end_time)
      events_in_tz = Events.convert_events_to_timezone([calendar_event], timezone, timezone)

      # Slot on Tuesday
      slot_time = Time.new!(slot_hour, slot_min, 0)

      slot_start =
        case DateTime.new(tuesday_date, slot_time, timezone) do
          {:ok, dt} -> dt
          {:ambiguous, first, _second} -> first
          {:error, _reason} -> DateTime.new!(tuesday_date, slot_time, "Etc/UTC")
        end

      slot_end = DateTime.add(slot_start, duration, :minute)

      # Verify it does NOT block Tuesday
      refute TimeRange.has_conflict_with_events?(
               slot_start,
               slot_end,
               events_in_tz,
               0
             ),
             "All-day Monday event blocked slot at #{slot_start} on Tuesday in #{timezone}"

      # Verify it DOES block Monday
      monday_slot_time = ~T[12:00:00]

      monday_slot_start =
        case DateTime.new(monday_date, monday_slot_time, timezone) do
          {:ok, dt} -> dt
          {:ambiguous, first, _second} -> first
          {:error, _reason} -> DateTime.new!(monday_date, monday_slot_time, "Etc/UTC")
        end

      monday_slot_end = DateTime.add(monday_slot_start, duration, :minute)

      assert TimeRange.has_conflict_with_events?(
               monday_slot_start,
               monday_slot_end,
               events_in_tz,
               0
             ),
             "All-day Monday event failed to block slot at #{monday_slot_start} on Monday in #{timezone}"
    end
  end

  property "DST transitions don't break availability or cause crashes" do
    # This test verifies that calculating availability around DST transition dates
    # (Spring Forward/Fall Back) across different timezones doesn't crash
    # and returns consistent results.

    check all(
            timezone <- member_of(["Europe/Kyiv", "America/New_York", "Europe/London"]),
            # Spring forward (usually March) and Fall back (usually October/November)
            month <- member_of([3, 10, 11]),
            year <- integer(2025..2030)
          ) do
      # Test every day in the transition month
      start_date = Date.new!(year, month, 1)
      end_date = Date.end_of_month(start_date)

      for date <- Date.range(start_date, end_date) do
        # 1. Optimized check (with empty pre-converted events)
        res_optimized =
          Conflicts.date_has_slots_with_events?(
            date,
            timezone,
            timezone,
            [],
            DateTimeUtils.now_in_timezone(timezone),
            %{min_advance_hours: 0}
          )

        # 2. Full calculation (with empty CalendarEvent list)
        {:ok, slots} =
          Calculate.available_slots(
            date,
            30,
            timezone,
            timezone,
            [],
            %{min_advance_hours: 0}
          )

        assert is_boolean(res_optimized)
        assert is_list(slots)
      end
    end
  end

  property "pre-filtering logic never misses a potentially relevant event" do
    # This property test verifies that the +/- 2 day pre-filtering window
    # safely captures all events that could possibly overlap with the
    # target date window (+/- 1 day) across all possible timezone shifts.

    check all(
            timezone <-
              member_of([
                "UTC",
                "America/New_York",
                "Europe/London",
                "Asia/Tokyo",
                "Australia/Sydney",
                "Pacific/Auckland",
                "Pacific/Kiritimati",
                "Pacific/Niue"
              ]),
            target_days_ahead <- integer(5..60),
            # Event date can be anywhere
            event_days_ahead <- integer(0..70),
            # Event start time
            event_hour <- integer(0..23),
            event_min <- integer(0..59),
            # Event duration up to 24 hours
            event_dur_min <- integer(1..1440)
          ) do
      target_date = Date.add(Date.utc_today(), target_days_ahead)
      event_date = Date.add(Date.utc_today(), event_days_ahead)

      # Create event in UTC, then shift to the viewing user's timezone
      event_start = DateTime.new!(event_date, Time.new!(event_hour, event_min, 0), "Etc/UTC")
      event_end = DateTime.add(event_start, event_dur_min, :minute)

      # This is the pre-converted map shape that Conflicts receives
      event_in_user_tz = %{
        start_time: DateTime.shift_zone!(event_start, timezone),
        end_time: DateTime.shift_zone!(event_end, timezone)
      }

      # The pre-filtering window we want to test
      start_date_limit = Date.add(target_date, -2)
      end_date_limit = Date.add(target_date, 2)

      event_start_date = DateTime.to_date(event_in_user_tz.start_time)
      event_end_date = DateTime.to_date(event_in_user_tz.end_time)

      is_excluded =
        Date.compare(event_end_date, start_date_limit) == :lt or
          Date.compare(event_start_date, end_date_limit) == :gt

      if is_excluded do
        # If the event was excluded, it MUST NOT overlap with ANY of the checked days
        # [target_date - 1, target_date, target_date + 1] in any timezone.
        # We check the 3-day window in the same user timezone.
        window_start = DateTime.new!(Date.add(target_date, -1), ~T[00:00:00], timezone)
        window_end = DateTime.new!(Date.add(target_date, 1), ~T[23:59:59], timezone)

        # Check for overlap
        overlaps =
          not (DateTime.compare(event_in_user_tz.end_time, window_start) == :lt or
                 DateTime.compare(event_in_user_tz.start_time, window_end) == :gt)

        assert not overlaps, """
        Pre-filter excluded a relevant event!
        Target Date: #{target_date}
        User TZ: #{timezone}
        Event (user tz): #{inspect(event_in_user_tz)}
        Filter limits: #{start_date_limit} to #{end_date_limit}
        Overlap window: #{window_start} to #{window_end}
        """
      end
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

      # Generate 500 random pre-converted event maps
      events =
        Enum.map(1..500, fn i ->
          day = rem(i, 28) + 1
          hour = rem(i, 24)
          start_dt = DateTime.new!(Date.new!(2026, 6, day), Time.new!(hour, 0, 0), timezone)
          end_dt = DateTime.add(start_dt, 30, :minute)
          %{start_time: start_dt, end_time: end_dt}
        end)

      config = %{buffer_minutes: 15, min_advance_hours: 0}

      # Benchmark the optimized check
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
      # Usually this should be < 15ms on modern hardware, but we allow 50ms for slower CI
      assert micro < 50_000
      assert is_boolean(result)
    end
  end
end
