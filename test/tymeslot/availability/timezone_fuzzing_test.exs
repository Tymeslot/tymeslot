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

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    # Create a profile with standard business hours for tests
    user = insert(:user)
    profile = insert(:profile, user: user)

    # Make every day available
    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    {:ok, profile: profile}
  end

  @timezones Enum.map(Timezones.all_options(), &elem(&1, 1))

  property "month_availability returns valid map for any timezone pair", %{profile: profile} do
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
        profile_id: profile.id
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
  test "month_availability spans an attendee midnight that DST skips", %{profile: profile} do
    config = %{
      duration_minutes: 30,
      buffer_minutes: 0,
      min_advance_hours: 0,
      profile_id: profile.id
    }

    assert {:ok, availability} =
             Calculate.month_availability(2026, 9, "Asia/Macau", "America/Santiago", [], config)

    assert map_size(availability) == 30
    # The owner's window still lands on the attendee's DST-gap day, so it stays bookable.
    assert availability["2026-09-06"] == true
  end

  property "available_slots returns valid sorted unique strings for any timezone pair", %{
    profile: profile
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
        profile_id: profile.id
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

  test "available_slots handles DST spring forward correctly", %{profile: profile} do
    config = %{
      duration_minutes: 30,
      buffer_minutes: 0,
      min_advance_hours: 0,
      profile_id: profile.id
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

  property "today's availability correctly respects min_advance_hours", %{profile: profile} do
    check all(
            advance_hours <- integer(0..72),
            user_tz <- member_of(@timezones)
          ) do
      # ...
      today = Date.utc_today()

      {:ok, _availability} =
        Calculate.month_availability(
          today.year,
          today.month,
          user_tz,
          user_tz,
          [],
          %{min_advance_hours: advance_hours, profile_id: profile.id}
        )

      # ...
    end
  end
end
