defmodule Tymeslot.Availability.BusinessHoursTest do
  @moduledoc """
  Tests for the BusinessHours module.
  """

  use ExUnit.Case, async: true

  @moduletag :availability

  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Availability.{BusinessHours, Calculate}
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Test.SlotGridHelpers

  describe "business_day?" do
    test "returns true for weekdays (default)" do
      # Monday to Friday
      assert BusinessHours.business_day?(~D[2026-01-12], nil)
      assert BusinessHours.business_day?(~D[2026-01-13], nil)
      assert BusinessHours.business_day?(~D[2026-01-14], nil)
      assert BusinessHours.business_day?(~D[2026-01-15], nil)
      assert BusinessHours.business_day?(~D[2026-01-16], nil)
    end

    test "returns false for weekends (default)" do
      # Saturday and Sunday
      refute BusinessHours.business_day?(~D[2026-01-17], nil)
      refute BusinessHours.business_day?(~D[2026-01-18], nil)
    end
  end

  describe "owner_windows/4" do
    # 2026-01-12 is a Monday (day_of_week 1), 2026-01-17 a Saturday.
    @monday ~D[2026-01-12]
    @saturday ~D[2026-01-17]

    test "nil schedule: the fallback hours resolve on the owner's date" do
      assert [%{date: @monday, start_dt: start_dt, end_dt: end_dt, breaks: []}] =
               BusinessHours.owner_windows([@monday], nil, "Etc/UTC", %{})

      assert DateTime.to_time(start_dt) == ~T[11:00:00]
      assert DateTime.to_time(end_dt) == ~T[19:30:00]
      assert start_dt.time_zone == "Etc/UTC"
    end

    test "weekend with no business hours yields no window (nil schedule)" do
      assert BusinessHours.owner_windows([@saturday], nil, "Etc/UTC", %{}) == []
    end

    test "windows are given in the owner's zone, one per date asked for" do
      schedule = [
        %{day_of_week: 7, is_available: true, start_time: ~T[22:00:00], end_time: ~T[23:00:00]},
        %{day_of_week: 1, is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]},
        %{day_of_week: 2, is_available: false}
      ]

      config = %{weekly_schedule: schedule, overrides: [], time_off: []}
      dates = [~D[2026-01-11], @monday, ~D[2026-01-13]]

      windows = BusinessHours.owner_windows(dates, 1, "America/New_York", config)

      assert Enum.map(windows, & &1.date) == [~D[2026-01-11], @monday]
      assert Enum.all?(windows, &(&1.start_dt.time_zone == "America/New_York"))

      # Sunday 22:00 New York (UTC-5) is Monday 12:00 in Tokyo, whichever
      # booker's date it ends up on.
      [sunday | _later] = windows
      assert DateTime.compare(sunday.start_dt, ~U[2026-01-12 03:00:00Z]) == :eq
      assert DateTime.compare(sunday.end_dt, ~U[2026-01-12 04:00:00Z]) == :eq
    end

    test "a Tokyo booker sees the New York owner's Sunday evening hours on Monday" do
      # What the old bleed test was really about: which slots the booker sees.
      schedule = [
        %{day_of_week: 7, start_time: ~T[22:00:00], end_time: ~T[23:00:00]}
      ]

      config = SlotGridHelpers.pure_config(days: schedule)

      assert SlotGridHelpers.labels(@monday, 30, "America/New_York", "Asia/Tokyo", config) ==
               ["12:00 PM", "12:30 PM"]
    end

    test "an overnight weekly row resolves its end on the next date" do
      schedule = [
        %{
          day_of_week: 1,
          is_available: true,
          start_time: ~T[22:00:00],
          end_time: ~T[02:00:00],
          ends_next_day: true
        }
      ]

      config = %{weekly_schedule: schedule, overrides: [], time_off: []}

      assert [%{start_dt: start_dt, end_dt: end_dt}] =
               BusinessHours.owner_windows([@monday], 1, "Etc/UTC", config)

      assert DateTime.to_date(start_dt) == @monday
      assert DateTime.to_date(end_dt) == ~D[2026-01-13]
      assert DateTime.to_time(end_dt) == ~T[02:00:00]
    end

    test "an unflagged row whose end is before its start yields no window" do
      schedule = [
        %{day_of_week: 1, is_available: true, start_time: ~T[22:00:00], end_time: ~T[02:00:00]}
      ]

      config = %{weekly_schedule: schedule, overrides: [], time_off: []}

      assert BusinessHours.owner_windows([@monday], 1, "Etc/UTC", config) == []
    end
  end

  describe "business_day?/3 with overnight hours and time off" do
    test "a day is a business day when only the previous day's overnight tail reaches into it" do
      # Monday 22:00 to Tuesday 02:00; Tuesday itself has no row of its own.
      schedule = [
        %{
          day_of_week: 1,
          is_available: true,
          start_time: ~T[22:00:00],
          end_time: ~T[02:00:00],
          ends_next_day: true
        }
      ]

      config = %{weekly_schedule: schedule, overrides: [], time_off: []}

      assert BusinessHours.business_day?(~D[2026-01-13], 1, config)
      refute BusinessHours.business_day?(~D[2026-01-14], 1, config)
    end

    test "an all-day time-off period makes a normally open day not a business day" do
      schedule = [
        %{day_of_week: 2, is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
      ]

      time_off = [
        %{starts_on: ~D[2026-01-13], ends_on: ~D[2026-01-13], start_time: nil, end_time: nil}
      ]

      open = %{weekly_schedule: schedule, overrides: [], time_off: []}

      assert BusinessHours.business_day?(~D[2026-01-13], 1, open)
      refute BusinessHours.business_day?(~D[2026-01-13], 1, %{open | time_off: time_off})
    end
  end

  describe "owner_windows/4 breaks" do
    test "a nil schedule carries no breaks" do
      assert [%{breaks: []}] = BusinessHours.owner_windows([~D[2026-01-12]], nil, "Etc/UTC", %{})
    end

    test "weekly breaks come back as intervals clipped to the window" do
      schedule = [
        %{
          day_of_week: 1,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00],
          breaks: [
            %{start_time: ~T[12:00:00], end_time: ~T[13:00:00]},
            %{start_time: ~T[15:00:00], end_time: ~T[15:15:00]}
          ]
        }
      ]

      assert [%{breaks: breaks}] =
               BusinessHours.owner_windows(
                 [~D[2026-01-12]],
                 1,
                 "Etc/UTC",
                 %{weekly_schedule: schedule, time_off: [], overrides: []}
               )

      assert Enum.map(breaks, fn {from, to} -> {DateTime.to_time(from), DateTime.to_time(to)} end) ==
               [{~T[12:00:00], ~T[13:00:00]}, {~T[15:00:00], ~T[15:15:00]}]
    end

    test "a row without a breaks key has none" do
      schedule = [
        %{day_of_week: 1, is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
      ]

      assert [%{breaks: []}] =
               BusinessHours.owner_windows(
                 [~D[2026-01-12]],
                 1,
                 "Etc/UTC",
                 %{weekly_schedule: schedule, time_off: [], overrides: []}
               )
    end

    test "a break outside the window is clipped away" do
      schedule = [
        %{
          day_of_week: 1,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00],
          breaks: [%{start_time: ~T[17:30:00], end_time: ~T[18:00:00]}]
        }
      ]

      assert [%{breaks: []}] =
               BusinessHours.owner_windows(
                 [~D[2026-01-12]],
                 1,
                 "Etc/UTC",
                 %{weekly_schedule: schedule, time_off: [], overrides: []}
               )
    end
  end

  describe "business hours starting inside a DST gap" do
    # Local times skipped by a spring-forward gap resolve to the end of the
    # gap, the same rule booking validation applies to the slot a booker
    # picks, so the offered slots and the bookable ones cannot drift apart.

    test "a window opening in the skipped hour starts when the clocks land" do
      # 2027-03-28 (a Sunday): Europe/Berlin jumps from 02:00 to 03:00, so the
      # owner's 02:30 opening does not exist that day.
      schedule = [
        %{day_of_week: 7, is_available: true, start_time: ~T[02:30:00], end_time: ~T[06:00:00]}
      ]

      config = %{weekly_schedule: schedule, overrides: [], time_off: []}

      assert [%{start_dt: start_dt, date: ~D[2027-03-28]}] =
               BusinessHours.owner_windows([~D[2027-03-28]], 1, "Europe/Berlin", config)

      assert DateTime.compare(start_dt, ~U[2027-03-28 01:00:00Z]) == :eq
    end

    test "a slot offered after a half-hour gap can be booked" do
      # 2026-10-04 (a Sunday): Australia/Lord_Howe jumps from 02:00 to 02:30.
      freeze_clock(~U[2026-10-01 00:00:00Z])
      timezone = "Australia/Lord_Howe"
      date = ~D[2026-10-04]

      schedule = [
        %{day_of_week: 7, is_available: true, start_time: ~T[02:15:00], end_time: ~T[04:15:00]}
      ]

      config = %{
        schedule_id: 1,
        weekly_schedule: schedule,
        overrides: [],
        time_off: [],
        min_advance_hours: 0,
        max_advance_booking_days: 365
      }

      assert {:ok, ["2:30 AM", "3:00 AM", "3:30 AM"]} =
               Calculate.available_slots(date, 30, timezone, timezone, [], config)

      assert {:ok, {start_datetime, _end_datetime}} =
               Validation.parse_meeting_times("2026-10-04", "2:30 AM", 30, timezone)

      assert {:ok, true} =
               Calculate.offers_slot(date, start_datetime, 30, timezone, timezone, config)
    end
  end
end
