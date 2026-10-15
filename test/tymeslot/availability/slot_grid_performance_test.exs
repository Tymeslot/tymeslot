defmodule Tymeslot.Availability.SlotGridPerformanceTest do
  @moduledoc """
  The worst case the spec's Risks section names for the slot engine: a 24/7
  host, a 5-minute interval and 24-hour meetings, so each booker day fits
  several hundred candidates, read for the 42 days of a month grid. The host
  is at UTC+14 and the booker at UTC-12, the widest pair, so every day reads
  the most owner days. A limit that refuses every start makes the month view
  test all of them instead of stopping at the first.

  The bound is generous on purpose: it catches an accidental blow-up (a grid
  walked from the wrong end, a quadratic fit), not a few per cent.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Utils.DateTimeUtils

  @owner_tz "Pacific/Kiritimati"
  @user_tz "Etc/GMT+12"
  @budget_ms 10_000

  setup do
    config =
      [
        days: every_day(%{start_time: ~T[00:00:00], end_time: ~T[00:00:00], ends_next_day: true}),
        interval: 5
      ]
      |> pure_config()
      |> Map.merge(%{
        duration_minutes: 1440,
        min_advance_hours: 0,
        max_advance_booking_days: 3650,
        owner_timezone: @owner_tz
      })

    today = @user_tz |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()
    %{config: config, from: Date.add(today, 1), to: Date.add(today, 42)}
  end

  test "a 42-day month view of the worst case stays within budget", %{
    config: config,
    from: from,
    to: to
  } do
    open = fn -> Calculate.range_availability(from, to, @owner_tz, @user_tz, [], config) end
    refusing = Map.put(config, :limit_checker, fn _start -> true end)
    closed = fn -> Calculate.range_availability(from, to, @owner_tz, @user_tz, [], refusing) end

    # Not vacuous: every day offers a start, and the refusing limit is what
    # makes every candidate get tested.
    assert {:ok, map} = open.()
    assert map_size(map) == 42 and Enum.all?(Map.values(map))
    assert {:ok, refused} = closed.()
    refute Enum.any?(Map.values(refused))

    {micros, _result} = :timer.tc(closed)

    assert div(micros, 1000) < @budget_ms,
           "42-day month view took #{div(micros, 1000)}ms (budget #{@budget_ms}ms)"
  end

  test "one day of the worst case lists every 5-minute start", %{config: config, from: from} do
    {micros, {:ok, slots}} =
      :timer.tc(fn ->
        Calculate.available_slots(from, 1440, @user_tz, @owner_tz, [], config)
      end)

    assert length(slots) == 288
    assert div(micros, 1000) < div(@budget_ms, 5)
  end
end
