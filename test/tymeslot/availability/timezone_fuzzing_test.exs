defmodule Tymeslot.Availability.TimezoneFuzzingTest do
  @moduledoc """
  Property-based tests to ensure availability logic is consistent across different timezones.
  """
  use ExUnit.Case, async: false

  @moduletag :availability

  use ExUnitProperties

  import Tymeslot.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Repo
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.DateTimeUtils

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    # Create a schedule with standard business hours for tests
    user = insert(:user)
    profile = insert(:profile, user: user)
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    # Make every day available
    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    {:ok, schedule: schedule}
  end

  @timezones Enum.map(Timezones.all_options(), &elem(&1, 1))

  property "month_availability returns valid map for any timezone pair", %{schedule: schedule} do
    check all(
            year <- integer(2026..2027),
            month <- integer(1..12),
            owner_tz <- member_of(@timezones),
            user_tz <- member_of(@timezones),
            duration <- member_of([30, 60])
          ) do
      config = %{
        duration_minutes: duration,
        buffer_minutes: 0,
        min_advance_hours: 0,
        schedule_id: schedule.id
      }

      {:ok, availability} =
        Calculate.month_availability(year, month, owner_tz, user_tz, [], config)

      # Result must be a map of date_string => boolean
      assert is_map(availability)

      for {date_str, available?} <- availability do
        assert is_binary(date_str), "Expected string date key, got: #{inspect(date_str)}"
        assert is_boolean(available?)

        {:ok, date} = Date.from_iso8601(date_str)
        assert date.year == year
        assert date.month == month
      end

      # Must cover all days in the month
      days_in_month = Date.days_in_month(Date.new!(year, month, 1))
      assert map_size(availability) == days_in_month
    end
  end

  # The property above only reaches this pair on some seeds. America/Santiago
  # has no midnight on 2026-09-06 (DST gap), and an owner in Asia/Macau pushes
  # availability across that boundary, so pin the case deterministically.
  test "month_availability spans an attendee midnight that DST skips", %{schedule: schedule} do
    config = %{
      duration_minutes: 30,
      buffer_minutes: 0,
      min_advance_hours: 0,
      schedule_id: schedule.id
    }

    assert {:ok, availability} =
             Calculate.month_availability(2026, 9, "Asia/Macau", "America/Santiago", [], config)

    assert map_size(availability) == 30
    # The owner's window still lands on the attendee's DST-gap day, so it stays bookable.
    assert availability["2026-09-06"] == true
  end

  property "available_slots returns valid sorted unique strings for any timezone pair", %{
    schedule: schedule
  } do
    check all(
            owner_tz <- member_of(@timezones),
            user_tz <- member_of(@timezones),
            duration <- member_of([30, 60])
          ) do
      config = %{
        duration_minutes: duration,
        buffer_minutes: 0,
        min_advance_hours: 0,
        schedule_id: schedule.id
      }

      date = Date.add(Date.utc_today(), 14)

      {:ok, slots} =
        Calculate.available_slots(date, duration, owner_tz, user_tz, [], config)

      assert is_list(slots)

      for slot <- slots do
        assert is_binary(slot), "Expected string slot, got: #{inspect(slot)}"
      end

      assert slots == Enum.sort_by(slots, &TimeSlots.parse_time_slot/1, Time),
             "Slots not in chronological order for #{owner_tz} -> #{user_tz}: #{inspect(slots)}"

      assert slots == Enum.uniq(slots),
             "Duplicate slots for #{owner_tz} -> #{user_tz}: #{inspect(slots)}"
    end
  end

  test "available_slots handles DST spring forward correctly", %{schedule: schedule} do
    config = %{
      duration_minutes: 30,
      buffer_minutes: 0,
      min_advance_hours: 0,
      schedule_id: schedule.id
    }

    # America/Santiago springs forward at 2026-09-06 00:00, so 00:00-00:59 does
    # not exist locally that day. An Asia/Macau owner's window covers it, so the
    # midnight slots must simply be dropped rather than offered or duplicated.
    assert {:ok, gap_day_slots} =
             Calculate.available_slots(
               ~D[2026-09-06],
               30,
               "America/Santiago",
               "Asia/Macau",
               [],
               config
             )

    refute "12:00 AM" in gap_day_slots
    refute "12:30 AM" in gap_day_slots
    assert "1:00 AM" in gap_day_slots
    assert gap_day_slots == Enum.uniq(gap_day_slots)

    assert gap_day_slots ==
             Enum.sort_by(gap_day_slots, &TimeSlots.parse_time_slot/1, Time)

    # The following week has no gap, so midnight is offered as normal.
    assert {:ok, normal_day_slots} =
             Calculate.available_slots(
               ~D[2026-09-13],
               30,
               "America/Santiago",
               "Asia/Macau",
               [],
               config
             )

    assert "12:00 AM" in normal_day_slots
    assert "12:30 AM" in normal_day_slots
  end

  property "month_availability respects min_advance_hours in any timezone", %{schedule: schedule} do
    check all(
            advance_hours <- integer(0..72),
            user_tz <- member_of(@timezones),
            max_runs: 30
          ) do
      today = user_tz |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()

      today_available? = day_available?(schedule, user_tz, advance_hours, today)

      # The schedule closes at 17:00, so no slot on the current day is ever a
      # full day out: a notice period of 24 hours or more must empty today.
      if advance_hours >= 24 do
        refute today_available?,
               "#{user_tz}: today is bookable despite #{advance_hours}h minimum notice"
      end

      # Availability is anti-monotone in the notice period — a day it rules
      # out cannot come back when the period grows.
      if today_available? do
        assert day_available?(schedule, user_tz, 0, today),
               "#{user_tz}: today is bookable at #{advance_hours}h notice but not at 0h"
      end

      # The generated notice period tops out at 72 hours, so a day a week out
      # stays bookable whichever value the run drew.
      next_week = Date.add(today, 7)

      assert day_available?(schedule, user_tz, advance_hours, next_week),
             "#{user_tz}: #{next_week} is unbookable at #{advance_hours}h notice"
    end
  end

  defp day_available?(schedule, user_tz, advance_hours, date) do
    {:ok, availability} =
      Calculate.month_availability(
        date.year,
        date.month,
        user_tz,
        user_tz,
        [],
        %{min_advance_hours: advance_hours, schedule_id: schedule.id}
      )

    Map.fetch!(availability, Date.to_string(date))
  end
end
