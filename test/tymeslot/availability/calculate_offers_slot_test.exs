defmodule Tymeslot.Availability.CalculateOffersSlotTest do
  @moduledoc """
  `Calculate.offers_slot/6` compares by instant against the list the booking
  page renders, so the date a start is listed under matters.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  import Tymeslot.Test.ClockHelpers
  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Availability.Calculate

  describe "offers_slot/6 and the date a start is listed under" do
    setup do
      freeze_clock(~U[2026-09-01 00:00:00Z])
    end

    defp offers_config(days) do
      [days: days]
      |> pure_config()
      |> Map.merge(%{min_advance_hours: 0, max_advance_booking_days: 3650})
    end

    test "accepts a post-midnight start under the date it begins on and refuses it under the previous date" do
      # Tokyo 09:00-17:00 on the 7th is Los Angeles 17:00 on the 6th to 01:00
      # on the 7th, so the booker's 7th opens with a start inside that window.
      config = offers_config(every_day(%{start_time: ~T[09:00:00], end_time: ~T[17:00:00]}))
      owner_tz = "Asia/Tokyo"
      user_tz = "America/Los_Angeles"
      after_midnight = DateTime.new!(~D[2026-09-07], ~T[00:00:00], user_tz)

      assert {:ok, true} =
               Calculate.offers_slot(
                 ~D[2026-09-07],
                 after_midnight,
                 30,
                 user_tz,
                 owner_tz,
                 config
               )

      assert {:ok, false} =
               Calculate.offers_slot(
                 ~D[2026-09-06],
                 after_midnight,
                 30,
                 user_tz,
                 owner_tz,
                 config
               )

      # The late-evening start the previous date does list is offered there.
      evening = DateTime.new!(~D[2026-09-06], ~T[23:30:00], user_tz)

      assert {:ok, true} =
               Calculate.offers_slot(~D[2026-09-06], evening, 30, user_tz, owner_tz, config)
    end

    test "refuses the second occurrence of a repeated fall-back hour" do
      # New York falls back on 2026-11-01: 01:00-02:00 happens twice.
      config = offers_config(every_day(%{start_time: ~T[00:00:00], end_time: ~T[04:00:00]}))
      zone = "America/New_York"
      date = ~D[2026-11-01]

      first = ~U[2026-11-01 05:30:00Z]
      second = ~U[2026-11-01 06:30:00Z]

      assert DateTime.to_date(DateTime.shift_zone!(first, zone)) == date
      assert DateTime.to_date(DateTime.shift_zone!(second, zone)) == date

      assert {:ok, true} = Calculate.offers_slot(date, first, 30, zone, zone, config)
      assert {:ok, false} = Calculate.offers_slot(date, second, 30, zone, zone, config)
    end
  end
end
