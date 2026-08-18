defmodule Tymeslot.Availability.ConflictsPropertyTest do
  @moduledoc """
  Property-based coverage for `Conflicts`: equivalence between the optimized
  boolean check and full slot calculation, all-day-event boundaries across
  timezones, DST transition safety, and pre-filtering completeness.

  Per-test unit coverage lives in `Tymeslot.Availability.ConflictsTest`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :availability

  alias Tymeslot.Availability.{Calculate, Conflicts, Events}
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Utils.{DateTimeUtils, TimeRange}

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
            days_ahead <- integer(5..60),
            duration <- member_of([15, 30, 45, 60, 90, 120]),
            buffer <- integer(0..60),
            events <-
              list_of(
                tuple({
                  integer(-3..3),
                  integer(0..23),
                  integer(0..59),
                  integer(15..480)
                }),
                max_length: 10
              )
          ) do
      date = Date.add(Date.utc_today(), days_ahead)
      config = %{buffer_minutes: buffer, min_advance_hours: 0, duration_minutes: duration}

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

      # Default business hours (Mon–Fri 11am–7:30pm); only check weekdays.
      if Date.day_of_week(date) in 1..5 do
        has_slots_optimized =
          Conflicts.date_has_slots_with_events?(
            date,
            timezone,
            timezone,
            events_in_tz,
            DateTimeUtils.now_in_timezone(timezone),
            config
          )

        {:ok, slots} =
          Calculate.available_slots(
            date,
            duration,
            timezone,
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
            monday_date <- constant(~D[2025-06-16]),
            tuesday_date <- constant(~D[2025-06-17]),
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

      events_in_tz = Events.convert_events_to_timezone([calendar_event], timezone, timezone)

      slot_time = Time.new!(slot_hour, slot_min, 0)

      slot_start =
        case DateTime.new(tuesday_date, slot_time, timezone) do
          {:ok, dt} -> dt
          {:ambiguous, first, _second} -> first
          {:error, _reason} -> DateTime.new!(tuesday_date, slot_time, "Etc/UTC")
        end

      slot_end = DateTime.add(slot_start, duration, :minute)

      refute TimeRange.has_conflict_with_events?(
               slot_start,
               slot_end,
               events_in_tz,
               0
             ),
             "All-day Monday event blocked slot at #{slot_start} on Tuesday in #{timezone}"

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
            month <- member_of([3, 10, 11]),
            year <- integer(2025..2030)
          ) do
      start_date = Date.new!(year, month, 1)
      end_date = Date.end_of_month(start_date)

      for date <- Date.range(start_date, end_date) do
        res_optimized =
          Conflicts.date_has_slots_with_events?(
            date,
            timezone,
            timezone,
            [],
            DateTimeUtils.now_in_timezone(timezone),
            %{min_advance_hours: 0}
          )

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

  property "the pre-filter never drops an event that still blocks the target day" do
    # `date_has_slots_with_events?/6` narrows the event list to ±2 days around
    # the target date before scanning slots. A long event that started days
    # earlier still blocks the target day, so dropping it would report the day
    # as bookable when it is fully taken.
    #
    # The pre-filter is exercised through the real call rather than restated
    # here, and the answer is checked against `available_slots/6`, which scans
    # the unnarrowed list: the two must agree.

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
            start_days_before <- integer(0..2),
            start_hour <- integer(0..23),
            duration_hours <- integer(1..72)
          ) do
      target_date = Date.add(Date.utc_today(), target_days_ahead)
      event_date = Date.add(target_date, -start_days_before)

      event_start =
        DateTimeUtils.create_datetime_safe(event_date, Time.new!(start_hour, 0, 0), timezone)

      event_end = DateTime.add(event_start, duration_hours, :hour)

      event =
        CalendarEvent.new!(%{
          uid: "prefilter-#{System.unique_integer([:positive])}",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "prefilter-#{System.unique_integer([:positive])}",
          provider_calendar_id: "primary",
          all_day: false,
          start_at: event_start,
          end_at: event_end,
          synced_at: DateTime.utc_now()
        })

      config = %{buffer_minutes: 0, min_advance_hours: 0, duration_minutes: 30}

      events_in_tz =
        [event]
        |> Enum.filter(&CalendarEvent.blocking?/1)
        |> Events.convert_events_to_timezone(timezone, timezone)

      # Default business hours are Mon–Fri, so only weekdays have slots at all.
      if Date.day_of_week(target_date) in 1..5 do
        has_slots_optimized =
          Conflicts.date_has_slots_with_events?(
            target_date,
            timezone,
            timezone,
            events_in_tz,
            DateTimeUtils.now_in_timezone(timezone),
            config
          )

        {:ok, slots} =
          Calculate.available_slots(target_date, 30, timezone, timezone, [event], config)

        assert has_slots_optimized == (slots != []), """
        Pre-filter dropped a relevant event!
        Target date: #{target_date}
        User TZ: #{timezone}
        Event (user tz): #{inspect(events_in_tz)}
        Optimised check: #{has_slots_optimized}, full check: #{slots != []}
        """
      end
    end
  end
end
