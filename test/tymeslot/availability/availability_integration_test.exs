defmodule Tymeslot.Availability.AvailabilityIntegrationTest do
  @moduledoc """
  Integration tests for availability calculation functionality.

  These tests validate that the availability calculation system works end-to-end,
  including profile settings, buffers, calendar conflicts, and slot generation.
  """

  use Tymeslot.DataCase, async: true

  alias Tymeslot.Availability.Calculate

  @moduletag :availability
  @moduletag :integration

  describe "availability calculation end-to-end" do
    test "generates time slots excluding conflicts" do
      profile = insert(:profile)

      schedule =
        insert(:availability_schedule, profile: profile, is_default: true, buffer_minutes: 15)

      date = next_monday()

      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: Date.day_of_week(date),
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      # Add existing meeting to create conflict
      calendar_events = [
        %{
          start_time: DateTime.new!(date, ~T[10:00:00], "America/New_York"),
          end_time: DateTime.new!(date, ~T[11:00:00], "America/New_York")
        }
      ]

      config = %{schedule_id: schedule.id, buffer_minutes: schedule.buffer_minutes}

      {:ok, slots} =
        Calculate.available_slots(
          date,
          # 30 minute duration
          30,
          "America/New_York",
          "America/New_York",
          calendar_events,
          config
        )

      # The meeting removes 10:00 and 10:30 outright; the 15-minute buffer also
      # removes 9:30 (which would end flush against it) and 11:00 (which would
      # start flush after it).
      assert slots == [
               "9:00 AM",
               "11:30 AM",
               "12:00 PM",
               "12:30 PM",
               "1:00 PM",
               "1:30 PM",
               "2:00 PM",
               "2:30 PM",
               "3:00 PM",
               "3:30 PM",
               "4:00 PM",
               "4:30 PM"
             ]
    end

    test "respects buffer time between meetings" do
      profile = insert(:profile)

      schedule =
        insert(:availability_schedule, profile: profile, is_default: true, buffer_minutes: 30)

      date = next_monday()

      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: Date.day_of_week(date),
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      # Existing meeting from 10:00-11:00
      calendar_events = [
        %{
          start_time: DateTime.new!(date, ~T[10:00:00], "America/New_York"),
          end_time: DateTime.new!(date, ~T[11:00:00], "America/New_York")
        }
      ]

      config = %{schedule_id: schedule.id, buffer_minutes: schedule.buffer_minutes}

      # A 15-minute duration makes the slot grid finer than the buffer, so the
      # buffer (not the grid) is what decides where bookings resume.
      {:ok, slots} =
        Calculate.available_slots(
          date,
          15,
          "America/New_York",
          "America/New_York",
          calendar_events,
          config
        )

      # Bookings stop 30 minutes before the meeting starts and resume 30 minutes
      # after it ends, rather than butting up against it.
      assert Enum.take(slots, 4) == ["9:00 AM", "9:15 AM", "11:30 AM", "11:45 AM"]
      assert List.last(slots) == "4:45 PM"
    end

    test "handles timezone conversions correctly" do
      profile = insert(:profile, timezone: "Europe/London")
      schedule = insert(:availability_schedule, profile: profile, is_default: true)

      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: 1,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      config = %{schedule_id: schedule.id, max_advance_booking_days: 7}

      # Test multiple timezones
      grids =
        for timezone <- ["America/New_York", "Europe/London", "Asia/Tokyo"] do
          days = Calculate.get_calendar_days(timezone, 2025, 1, config)

          assert length(days) == 42
          # January 2025 is wholly in the past in every timezone.
          assert Enum.all?(days, & &1.past)

          Enum.map(days, & &1.date)
        end

      # The displayed grid is a property of the month, not of the viewer's zone.
      assert [grid, grid, grid] = grids
    end

    test "excludes slots with advance booking restrictions" do
      profile = insert(:profile)

      schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: true,
          min_advance_hours: 24,
          advance_booking_days: 30
        )

      # Availability on every weekday, so which weekday the suite runs on cannot
      # decide whether the assertions below are exercised.
      for day_of_week <- 1..7 do
        insert(:weekly_availability,
          schedule: schedule,
          day_of_week: day_of_week,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )
      end

      config = %{
        schedule_id: schedule.id,
        min_advance_hours: schedule.min_advance_hours,
        max_advance_booking_days: schedule.advance_booking_days
      }

      # Control: a day sitting inside the booking window does offer slots, so an
      # empty list below means the restriction bit, not that setup went missing.
      {:ok, future_slots} =
        Calculate.available_slots(
          next_monday(),
          30,
          "America/New_York",
          "America/New_York",
          [],
          config
        )

      refute future_slots == []

      # Today, by contrast, lies wholly within the 24-hour minimum notice.
      {:ok, today_slots} =
        Calculate.available_slots(
          Date.utc_today(),
          30,
          "America/New_York",
          "America/New_York",
          [],
          config
        )

      assert today_slots == []
    end
  end

  # A fixed weekday keeps the expected slot lists deterministic: anchoring on
  # "tomorrow" silently skipped the whole assertion on Fridays and Saturdays.
  defp next_monday do
    today = Date.utc_today()
    Date.add(today, rem(1 - Date.day_of_week(today) + 7, 7) + 7)
  end
end
