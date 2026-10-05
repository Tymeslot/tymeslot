defmodule Tymeslot.Availability.LegacySlotEngineTest do
  @moduledoc """
  Pins `Tymeslot.Test.LegacySlotEngine` to the engine it copies. While this
  passes, the oracle is a faithful record of what existing schedules offered,
  and the properties that compare the new engine against it mean something.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :availability

  import Tymeslot.Test.ClockHelpers
  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Test.LegacySlotEngine
  alias Tymeslot.Test.ScheduleGenerators, as: Gen

  # The real engine applies notice and the booking window against the clock,
  # so the clock is frozen before every generated date and both rules are
  # opened wide: the comparison is about the schedule alone.
  setup do
    freeze_clock(~U[2027-01-01 00:00:00Z])
    on_exit(&unfreeze_clock/0)
    :ok
  end

  property "the oracle offers exactly what the engine offers" do
    check all(
            date <- Gen.date(),
            owner_tz <- Gen.zone(),
            user_tz <- Gen.zone(),
            duration <- Gen.duration(),
            interval <- Gen.interval(),
            days <- Gen.week(Gen.legacy_window()),
            overrides <- Gen.overrides(date, Gen.legacy_window()),
            time_off <- Gen.time_off(date),
            max_runs: 400
          ) do
      config =
        pure_config(days: days, overrides: overrides, time_off: time_off, interval: interval)

      {:ok, engine} =
        Calculate.available_slots(
          date,
          duration,
          user_tz,
          owner_tz,
          [],
          Map.merge(config, %{min_advance_hours: 0, max_advance_booking_days: 3650})
        )

      assert LegacySlotEngine.slots(date, duration, owner_tz, user_tz, config) == engine
    end
  end

  test "the oracle is not vacuous: it offers slots and cuts windows at the booker's midnight" do
    config = pure_config(days: every_day(%{start_time: ~T[09:00:00], end_time: ~T[17:00:00]}))

    assert LegacySlotEngine.slots(~D[2027-06-15], 60, "Europe/London", "Asia/Tokyo", config) ==
             ["12:00 AM", "5:00 PM", "6:00 PM", "7:00 PM", "8:00 PM", "9:00 PM", "10:00 PM"]

    assert LegacySlotEngine.cuts_window?(~D[2027-06-15], "Europe/London", "Asia/Tokyo", config)
    refute LegacySlotEngine.cuts_window?(~D[2027-06-15], "Europe/London", "Europe/London", config)
  end
end
