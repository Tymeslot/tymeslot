defmodule Tymeslot.Availability.TimeOffTimezoneTest do
  @moduledoc """
  Time off as a booker on another clock sees it.

  A period is stored in the owner's timezone, but the booking page asks for
  the slots of a date in the booker's. The two dates only coincide when the
  clocks do, so these pin the cases where they part: an owner day that
  straddles two booker dates, and a week where one side has changed its clocks
  for daylight saving and the other has not.

  Pure calculations: every prefetch key is supplied, so no query is made.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Availability.Calculate

  @now DateTime.new!(~D[2026-09-01], ~T[00:00:00], "Etc/UTC")

  # `available_slots/6` drops slots that have already passed, so "now" is
  # pinned before every fixed date below.
  setup do
    freeze_clock(@now)
  end

  describe "an owner in Kolkata and a booker in New York" do
    # 2026-09-07 is a Monday. Kolkata is UTC+5:30 and New York UTC-4 in
    # September, so the owner's 09:00-17:00 Monday is New York's Sunday 23:30
    # to Monday 07:30, and the owner's Tuesday begins at 23:30 on the booker's
    # Monday.
    @monday ~D[2026-09-07]
    @sunday ~D[2026-09-06]

    test "a whole day off on the owner's Monday empties the booker's Monday morning" do
      assert "7:00 AM" in slots(@monday, "America/New_York", "Asia/Kolkata", [])

      time_off = [whole_days(@monday, @monday)]
      slots = slots(@monday, "America/New_York", "Asia/Kolkata", time_off)

      refute "12:00 AM" in slots
      refute "7:00 AM" in slots
    end

    # These two use 15-minute slots: a 30-minute one starting at 23:30 would
    # end on the next booker date, which the grid never offers, time off or not.
    test "a whole day off on the owner's Monday also clears the booker's Sunday night" do
      assert "11:30 PM" in slots(@sunday, "America/New_York", "Asia/Kolkata", [], 15)

      time_off = [whole_days(@monday, @monday)]

      refute "11:30 PM" in slots(@sunday, "America/New_York", "Asia/Kolkata", time_off, 15)
    end

    test "leaves the owner's next day bookable where it begins on the booker's date" do
      time_off = [whole_days(@monday, @monday)]

      assert "11:30 PM" in slots(@monday, "America/New_York", "Asia/Kolkata", time_off, 15)
    end

    test "a part-day window is cut at the owner's wall-clock times" do
      # Kolkata 13:00-17:00 is New York 03:30-07:30.
      time_off = [
        %{starts_on: @monday, ends_on: @monday, start_time: ~T[13:00:00], end_time: ~T[17:00:00]}
      ]

      slots = slots(@monday, "America/New_York", "Asia/Kolkata", time_off)

      assert "3:00 AM" in slots
      refute "3:30 AM" in slots
      refute "7:00 AM" in slots
    end
  end

  describe "a week where only one side has left summer time" do
    # Berlin leaves CEST on 2026-10-25; New York stays on EDT until 2026-11-01.
    # On Monday 2026-10-26 the gap is five hours, not the usual six, so a
    # window resolved with the wrong offset lands an hour out.
    @dst_monday ~D[2026-10-26]

    test "a part-day window follows the owner's offset on that date" do
      # Berlin 13:00-17:00 CET is New York 08:00-12:00 EDT.
      time_off = [
        %{
          starts_on: @dst_monday,
          ends_on: @dst_monday,
          start_time: ~T[13:00:00],
          end_time: ~T[17:00:00]
        }
      ]

      slots = slots(@dst_monday, "America/New_York", "Europe/Berlin", time_off)

      assert "7:30 AM" in slots
      refute "8:00 AM" in slots
      refute "11:30 AM" in slots
    end
  end

  defp slots(date, booker_timezone, owner_timezone, time_off, duration \\ 30) do
    {:ok, slots} =
      Calculate.available_slots(
        date,
        duration,
        booker_timezone,
        owner_timezone,
        [],
        config(time_off)
      )

    slots
  end

  defp whole_days(starts_on, ends_on),
    do: %{starts_on: starts_on, ends_on: ends_on, start_time: nil, end_time: nil}

  defp config(time_off) do
    %{
      schedule_id: 1,
      weekly_schedule:
        for day_of_week <- 1..5 do
          %{
            day_of_week: day_of_week,
            is_available: true,
            start_time: ~T[09:00:00],
            end_time: ~T[17:00:00],
            breaks: []
          }
        end,
      overrides: [],
      time_off: time_off,
      min_advance_hours: 0,
      max_advance_booking_days: 3650,
      buffer_minutes: 0
    }
  end
end
