defmodule Tymeslot.Availability.MidnightRewritePropertyTest do
  @moduledoc """
  What rewriting 23:59 ends to midnight does to bookers: every slot the old
  engine offered is still offered, and every slot gained runs past an old
  23:59 end (it starts at or before it and ends after it). Compared, like the
  oracle property, only where the booker's midnight cuts no old window.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :availability

  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Test.{LegacySlotEngine, MidnightRewrite}
  alias Tymeslot.Test.ScheduleGenerators, as: Gen
  alias Tymeslot.Utils.DateTimeUtils

  @gained :midnight_rewrite_gained

  property "a rewritten schedule keeps its slots and gains only slots past the old end" do
    Process.put(@gained, 0)

    check all(
            date <- Gen.date(),
            owner_tz <- Gen.zone(),
            user_tz <- Gen.zone(),
            duration <- Gen.duration(),
            interval <- Gen.interval(),
            days <- Gen.week(Gen.legacy_window()),
            overrides <- Gen.overrides(date, Gen.legacy_window()),
            time_off <- Gen.time_off(date),
            max_runs: 500
          ) do
      before =
        pure_config(days: days, overrides: overrides, time_off: time_off, interval: interval)

      unless LegacySlotEngine.cuts_window?(date, owner_tz, user_tz, before) do
        old = LegacySlotEngine.round_trip_slots(date, duration, owner_tz, user_tz, before)
        new = labels(date, duration, owner_tz, user_tz, MidnightRewrite.apply(before))

        assert old -- new == [], "the rewrite lost slots: #{inspect(old -- new)}"

        old_ends = old_ends(before, date, owner_tz)

        stray =
          Enum.reject(new -- old, fn label ->
            {:ok, time} = DateTimeUtils.parse_time_string(label)
            {:ok, start} = DateTimeUtils.resolve_local(date, time, user_tz)
            finish = DateTime.add(start, duration, :minute)

            Enum.any?(
              old_ends,
              &(DateTime.compare(start, &1) != :gt and DateTime.compare(finish, &1) == :gt)
            )
          end)

        assert stray == [],
               "gained slots that do not run past an old 23:59 end: #{inspect(stray)}"

        if new != old, do: Process.put(@gained, Process.get(@gained) + 1)
      end
    end

    assert Process.get(@gained) > 0, "no run gained a slot, so the rewrite was never exercised"
  end

  # Every 23:59 instant a rewritten row could have ended at, around the date.
  # Over-approximates (an override hides its weekday's row), which only makes
  # the check more permissive, never wrong.
  defp old_ends(config, date, owner_tz) do
    for owner_date <- Date.range(Date.add(date, -3), Date.add(date, 3)),
        rewritten_on?(config, owner_date),
        {:ok, instant} = DateTimeUtils.resolve_local(owner_date, ~T[23:59:00], owner_tz),
        do: instant
  end

  defp rewritten_on?(config, owner_date) do
    Enum.any?(config.overrides, &(&1.date == owner_date and MidnightRewrite.rewritten?(&1))) or
      Enum.any?(
        config.weekly_schedule,
        &(&1.day_of_week == Date.day_of_week(owner_date) and MidnightRewrite.rewritten?(&1))
      )
  end
end
