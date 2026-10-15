defmodule Tymeslot.Availability.LegacySlotEngineTest do
  @moduledoc """
  Compares the slot engine with `Tymeslot.Test.LegacySlotEngine`, the frozen
  copy of the engine as it stood before overnight windows, so that existing
  schedules keep the slots they offered wherever the spec promises no change.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :availability

  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Test.LegacySlotEngine
  alias Tymeslot.Test.ScheduleGenerators, as: Gen

  # The spec promises identical offers wherever the booker's midnight cuts no
  # window; where it does, the straddling slot and the realigned grid are the
  # intended change (pinned by example in `SlotGridTest`). The new engine also
  # lists only labels that resolve back to their own instant, which the old
  # one did not guarantee in a fall-back hour, so the comparison is against
  # those labels.
  #
  # Windows ending at 23:59 or 23:59:59 are generated as stored, unflagged:
  # the editor never offered such an end, but a row written through the
  # database can hold one, and the new engine must read it exactly as the old
  # one did (23:59:59 reads as 23:59, which changes no minute-aligned slot).
  #
  # Only runs where the old engine listed something are counted towards the
  # floor below: an empty day on both sides compares nothing.
  @compared :legacy_property_compared

  property "existing schedules keep their slots wherever the booker's midnight cuts no window" do
    Process.put(@compared, 0)

    check all(
            date <- Gen.date(),
            owner_tz <- Gen.zone(),
            user_tz <- Gen.zone(),
            duration <- Gen.duration(),
            interval <- Gen.interval(),
            days <- Gen.week(Gen.legacy_window()),
            overrides <- Gen.overrides(date, Gen.legacy_window()),
            time_off <- Gen.time_off(date),
            max_runs: 3_000
          ) do
      config =
        pure_config(days: days, overrides: overrides, time_off: time_off, interval: interval)

      unless LegacySlotEngine.cuts_window?(date, owner_tz, user_tz, config) do
        legacy = LegacySlotEngine.round_trip_slots(date, duration, owner_tz, user_tz, config)
        if legacy != [], do: Process.put(@compared, Process.get(@compared) + 1)

        assert labels(date, duration, owner_tz, user_tz, config) == legacy
      end
    end

    assert Process.get(@compared) > 300, "too few runs compared any slot; the generators drifted"
  end

  # Where the booker's midnight does cut a window, the spec promises a pure
  # addition when the interval divides the hour: the old engine restarted the
  # grid at the booker's midnight but aligned it on the owner's clock, which
  # is the same lattice the window's own grid steps along, and it only ever
  # dropped the slot that ran past the booker's midnight. So every slot the
  # old engine listed is still listed. A nil interval or one of 45, 90 or 120
  # minutes moves later starts instead (spec example 4), so those runs are
  # left out.
  @cut_compared :legacy_cut_property_compared

  property "where the booker's midnight cuts a window, an interval that divides the hour only adds slots" do
    Process.put(@cut_compared, 0)

    check all(
            date <- Gen.date(),
            owner_tz <- Gen.zone(),
            user_tz <- Gen.zone(),
            duration <- Gen.duration(),
            interval <- member_of([15, 30, 60]),
            days <- Gen.week(Gen.legacy_window()),
            overrides <- Gen.overrides(date, Gen.legacy_window()),
            time_off <- Gen.time_off(date),
            max_runs: 1_500
          ) do
      config =
        pure_config(days: days, overrides: overrides, time_off: time_off, interval: interval)

      if LegacySlotEngine.cuts_window?(date, owner_tz, user_tz, config) do
        legacy = LegacySlotEngine.round_trip_slots(date, duration, owner_tz, user_tz, config)
        if legacy != [], do: Process.put(@cut_compared, Process.get(@cut_compared) + 1)

        assert legacy -- labels(date, duration, owner_tz, user_tz, config) == []
      end
    end

    assert Process.get(@cut_compared) > 200,
           "too few runs compared any slot; the generators drifted"
  end

  test "the oracle is not vacuous: it offers slots and cuts windows at the booker's midnight" do
    config = pure_config(days: every_day(%{start_time: ~T[09:00:00], end_time: ~T[17:00:00]}))

    assert LegacySlotEngine.slots(~D[2027-06-15], 60, "Europe/London", "Asia/Tokyo", config) ==
             ["12:00 AM", "5:00 PM", "6:00 PM", "7:00 PM", "8:00 PM", "9:00 PM", "10:00 PM"]

    assert LegacySlotEngine.cuts_window?(~D[2027-06-15], "Europe/London", "Asia/Tokyo", config)
    refute LegacySlotEngine.cuts_window?(~D[2027-06-15], "Europe/London", "Europe/London", config)
  end
end
