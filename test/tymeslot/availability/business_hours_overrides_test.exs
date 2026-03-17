defmodule Tymeslot.Availability.BusinessHoursOverridesTest do
  @moduledoc """
  Tests that date-specific availability overrides take precedence over weekly schedule
  in business hours calculations.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability

  alias Tymeslot.Availability.BusinessHours
  alias Tymeslot.Availability.WeeklySchedule

  # April 6, 2026 is a Monday (day_of_week 1)
  @monday ~D[2026-04-06]
  # April 4, 2026 is a Saturday (day_of_week 6)
  @saturday ~D[2026-04-04]

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)
    %{profile: profile}
  end

  describe "business_day?/2 with overrides" do
    test "unavailable override marks a normally-available day as not a business day", %{
      profile: profile
    } do
      WeeklySchedule.upsert_day_availability(profile.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      insert(:availability_override,
        profile: profile,
        date: @monday,
        override_type: "unavailable",
        reason: "Public holiday"
      )

      refute BusinessHours.business_day?(@monday, profile.id)
    end

    test "custom_hours override marks a normally-unavailable day as a business day", %{
      profile: profile
    } do
      insert(:availability_override,
        profile: profile,
        date: @saturday,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert BusinessHours.business_day?(@saturday, profile.id)
    end

    test "available override marks a normally-unavailable day as a business day", %{
      profile: profile
    } do
      insert(:availability_override,
        profile: profile,
        date: @saturday,
        override_type: "available"
      )

      assert BusinessHours.business_day?(@saturday, profile.id)
    end

    test "with no override falls through to weekly schedule", %{profile: profile} do
      WeeklySchedule.upsert_day_availability(profile.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      assert BusinessHours.business_day?(@monday, profile.id)
      refute BusinessHours.business_day?(@saturday, profile.id)
    end
  end

  describe "get_business_hours_in_timezone/4 with overrides" do
    test "unavailable override returns nil hours even when weekly schedule has hours", %{
      profile: profile
    } do
      WeeklySchedule.upsert_day_availability(profile.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      insert(:availability_override,
        profile: profile,
        date: @monday,
        override_type: "unavailable",
        reason: "Holiday"
      )

      assert {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: @monday}} =
               BusinessHours.get_business_hours_in_timezone(
                 @monday,
                 profile.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )
    end

    test "custom_hours override returns override times, ignoring weekly schedule", %{
      profile: profile
    } do
      WeeklySchedule.upsert_day_availability(profile.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      insert(:availability_override,
        profile: profile,
        date: @monday,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert {:ok, %{start_datetime: start_dt, end_datetime: end_dt}} =
               BusinessHours.get_business_hours_in_timezone(
                 @monday,
                 profile.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )

      assert DateTime.to_time(start_dt) == ~T[10:00:00]
      assert DateTime.to_time(end_dt) == ~T[14:00:00]
    end

    test "custom_hours override on a normally-unavailable day returns those hours", %{
      profile: profile
    } do
      insert(:availability_override,
        profile: profile,
        date: @saturday,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert {:ok, %{start_datetime: %DateTime{}, end_datetime: %DateTime{}}} =
               BusinessHours.get_business_hours_in_timezone(
                 @saturday,
                 profile.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )
    end

    test "no override falls through to weekly schedule", %{profile: profile} do
      WeeklySchedule.upsert_day_availability(profile.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      })

      assert {:ok, %{start_datetime: start_dt, end_datetime: end_dt}} =
               BusinessHours.get_business_hours_in_timezone(
                 @monday,
                 profile.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )

      assert DateTime.to_time(start_dt) == ~T[09:00:00]
      assert DateTime.to_time(end_dt) == ~T[17:00:00]
    end

    test "no override on a day with no weekly schedule returns nil hours", %{profile: profile} do
      assert {:ok, %{start_datetime: nil, end_datetime: nil}} =
               BusinessHours.get_business_hours_in_timezone(
                 @saturday,
                 profile.id,
                 "Etc/UTC",
                 "Etc/UTC"
               )
    end

    test "override times are correctly converted to user timezone", %{profile: profile} do
      insert(:availability_override,
        profile: profile,
        date: @monday,
        override_type: "custom_hours",
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      # Owner is UTC, user is UTC-5 (America/New_York in April = EDT = UTC-4)
      assert {:ok, %{start_datetime: start_dt, end_datetime: end_dt}} =
               BusinessHours.get_business_hours_in_timezone(
                 @monday,
                 profile.id,
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
