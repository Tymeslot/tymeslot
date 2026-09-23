defmodule Tymeslot.Availability.BusinessHoursOverridesTest do
  @moduledoc """
  Tests that date-specific availability overrides take precedence over weekly schedule
  in business hours calculations.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability

  alias Tymeslot.Availability.BusinessHours
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.WeeklySchedule

  # April 6, 2026 is a Monday (day_of_week 1)
  @monday ~D[2026-04-06]
  # April 4, 2026 is a Saturday (day_of_week 6)
  @saturday ~D[2026-04-04]

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    %{schedule: schedule}
  end

  describe "business_day?/2 with overrides" do
    test "unavailable override marks a normally-available day as not a business day", %{
      schedule: schedule
    } do
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      insert(:availability_override,
        schedule: schedule,
        date: @monday,
        override_type: "unavailable",
        reason: "Public holiday"
      )

      refute BusinessHours.business_day?(@monday, schedule.id)
    end

    test "custom_hours override marks a normally-unavailable day as a business day", %{
      schedule: schedule
    } do
      insert(:availability_override,
        schedule: schedule,
        date: @saturday,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert BusinessHours.business_day?(@saturday, schedule.id)
    end

    test "available override with no hours leaves a normally-unavailable day closed", %{
      schedule: schedule
    } do
      insert(:availability_override,
        schedule: schedule,
        date: @saturday,
        override_type: "available"
      )

      refute BusinessHours.business_day?(@saturday, schedule.id)
    end

    test "available override with no hours agrees with the hours the day offers", %{
      schedule: schedule
    } do
      insert(:availability_override,
        schedule: schedule,
        date: @saturday,
        override_type: "available"
      )

      assert {:ok, %{start_datetime: nil, end_datetime: nil}} =
               BusinessHours.get_business_hours_in_timezone(
                 @saturday,
                 schedule.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )

      refute BusinessHours.business_day?(@saturday, schedule.id)
    end

    test "available override opens a day the weekly pattern already has hours for", %{
      schedule: schedule
    } do
      WeeklySchedule.upsert_day_availability(schedule.id, 6, %{
        is_available: true,
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      })

      insert(:availability_override,
        schedule: schedule,
        date: @saturday,
        override_type: "available"
      )

      assert BusinessHours.business_day?(@saturday, schedule.id)
    end

    test "with no override falls through to weekly schedule", %{schedule: schedule} do
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      assert BusinessHours.business_day?(@monday, schedule.id)
      refute BusinessHours.business_day?(@saturday, schedule.id)
    end
  end

  describe "the booking page's reading of a day with no hours" do
    # The week strip renders each day through this function
    # (`CalendarHelpers.business_hours_lookup/5`), so it is where an override
    # that opens a day without hours becomes a day a visitor can click into and
    # find empty. The date is chosen forward of today and inside the advance
    # booking window, or the day is unbookable for reasons that have nothing to
    # do with the override.
    setup %{schedule: schedule} do
      today = Date.utc_today()
      saturday = Date.add(today, rem(13 - Date.day_of_week(today), 7) + 7)

      %{schedule: schedule, saturday: saturday}
    end

    test "an available override with no hours does not open the day", %{
      schedule: schedule,
      saturday: saturday
    } do
      insert(:availability_override,
        schedule: schedule,
        date: saturday,
        override_type: "available"
      )

      refute Calculate.day_bookable_by_business_hours?(saturday, "Etc/UTC", %{
               schedule_id: schedule.id
             })
    end

    test "the same day opens once the override names hours", %{
      schedule: schedule,
      saturday: saturday
    } do
      insert(:availability_override,
        schedule: schedule,
        date: saturday,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert Calculate.day_bookable_by_business_hours?(saturday, "Etc/UTC", %{
               schedule_id: schedule.id
             })
    end
  end

  describe "get_business_hours_in_timezone/4 with overrides" do
    test "unavailable override returns nil hours even when weekly schedule has hours", %{
      schedule: schedule
    } do
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      insert(:availability_override,
        schedule: schedule,
        date: @monday,
        override_type: "unavailable",
        reason: "Holiday"
      )

      assert {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: @monday}} =
               BusinessHours.get_business_hours_in_timezone(
                 @monday,
                 schedule.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )
    end

    test "custom_hours override returns override times, ignoring weekly schedule", %{
      schedule: schedule
    } do
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      insert(:availability_override,
        schedule: schedule,
        date: @monday,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert {:ok, %{start_datetime: start_dt, end_datetime: end_dt}} =
               BusinessHours.get_business_hours_in_timezone(
                 @monday,
                 schedule.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )

      assert DateTime.to_time(start_dt) == ~T[10:00:00]
      assert DateTime.to_time(end_dt) == ~T[14:00:00]
    end

    test "custom_hours override on a normally-unavailable day returns those hours", %{
      schedule: schedule
    } do
      insert(:availability_override,
        schedule: schedule,
        date: @saturday,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert {:ok, %{start_datetime: %DateTime{}, end_datetime: %DateTime{}}} =
               BusinessHours.get_business_hours_in_timezone(
                 @saturday,
                 schedule.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )
    end

    test "no override falls through to weekly schedule", %{schedule: schedule} do
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      assert {:ok, %{start_datetime: start_dt, end_datetime: end_dt}} =
               BusinessHours.get_business_hours_in_timezone(
                 @monday,
                 schedule.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )

      assert DateTime.to_time(start_dt) == ~T[09:00:00]
      assert DateTime.to_time(end_dt) == ~T[17:00:00]
    end

    test "no override on a day with no weekly schedule returns nil hours", %{schedule: schedule} do
      assert {:ok, %{start_datetime: nil, end_datetime: nil}} =
               BusinessHours.get_business_hours_in_timezone(
                 @saturday,
                 schedule.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )
    end

    test "override times are correctly converted to user timezone", %{schedule: schedule} do
      insert(:availability_override,
        schedule: schedule,
        date: @monday,
        override_type: "custom_hours",
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      # Owner is UTC, user is UTC-5 (America/New_York in April = EDT = UTC-4)
      assert {:ok, %{start_datetime: start_dt, end_datetime: end_dt}} =
               BusinessHours.get_business_hours_in_timezone(
                 @monday,
                 schedule.id,
                 "Etc/UTC",
                 "America/New_York"
               )

      # 09:00 UTC = 05:00 EDT
      assert start_dt.time_zone == "America/New_York"
      assert DateTime.to_time(start_dt) == ~T[05:00:00]
      assert DateTime.to_time(end_dt) == ~T[13:00:00]
    end
  end
end
