defmodule Tymeslot.Availability.TimeOffSlotsIntegrationTest do
  @moduledoc """
  End-to-end coverage of time off through the availability engine: what a
  booker is offered on the time picker (`Calculate.available_slots/6`), what
  the calendar grid marks bookable (`Calculate.range_availability/6` and
  `BusinessHours.business_day?/3`), and what the booking gate re-derives when
  a submitted slot arrives (`Calculate.offers_slot/6`).

  The three must agree: a day the grid still offers but the picker refuses is
  the failure this feature would produce most easily, since time off is read
  at a different point in each path.

  Also pins the precedence rule — a profile-wide period outranks a
  per-schedule `available` override — which is the one place time off and the
  existing override system can contradict each other.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.BusinessHours
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Utils.DateTimeUtils

  @timezone "Europe/Berlin"

  describe "whole-day time off" do
    test "removes every slot from the day it covers and leaves neighbouring days alone" do
      {profile, schedule, monday} = weekday_schedule()

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: Date.add(monday, 1),
        start_time: nil,
        end_time: nil
      )

      assert {:ok, []} = slots(monday, schedule)
      assert {:ok, []} = slots(Date.add(monday, 1), schedule)

      {:ok, after_period} = slots(Date.add(monday, 2), schedule)
      assert "9:00 AM" in after_period
    end

    test "takes the day off the calendar grid as well as the time picker" do
      # The grid and the picker read time off at different points —
      # business_day?/3 and the slot filter — so a change that satisfies one
      # can leave the other offering a day that cannot be booked.
      {profile, schedule, monday} = weekday_schedule()

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: monday
      )

      refute BusinessHours.business_day?(monday, schedule.id, %{})

      assert {:ok, availability} =
               Calculate.range_availability(
                 monday,
                 Date.add(monday, 2),
                 @timezone,
                 @timezone,
                 [],
                 config(schedule)
               )

      refute availability[Date.to_string(monday)]
      assert availability[Date.to_string(Date.add(monday, 2))]
    end

    test "refuses a booking submitted for a covered day" do
      {profile, schedule, monday} = weekday_schedule()

      start_datetime = DateTimeUtils.create_datetime_safe(monday, ~T[10:00:00], @timezone)

      assert {:ok, true} =
               Calculate.offers_slot(
                 monday,
                 start_datetime,
                 30,
                 @timezone,
                 @timezone,
                 config(schedule)
               )

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: monday
      )

      assert {:ok, false} =
               Calculate.offers_slot(
                 monday,
                 start_datetime,
                 30,
                 @timezone,
                 @timezone,
                 config(schedule)
               )
    end

    test "outranks an override that declares the same date available" do
      {profile, schedule, saturday} = unavailable_saturday_schedule()

      insert(:availability_override,
        schedule: schedule,
        date: saturday,
        override_type: "available",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      {:ok, without_time_off} = slots(saturday, schedule)
      assert "10:00 AM" in without_time_off

      insert(:time_off_period,
        profile: profile,
        starts_on: saturday,
        ends_on: saturday
      )

      assert {:ok, []} = slots(saturday, schedule)
    end

    test "applies to every schedule the profile owns, not only the default" do
      # The reason a period hangs off the profile: a second schedule must not
      # stay quietly bookable through a holiday entered once.
      {profile, default_schedule, monday} = weekday_schedule()

      second =
        insert(:availability_schedule, profile: profile, is_default: false, buffer_minutes: 0)

      insert(:weekly_availability,
        schedule: second,
        day_of_week: Date.day_of_week(monday),
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      {:ok, before_period} = slots(monday, second)
      assert "9:00 AM" in before_period

      insert(:time_off_period, profile: profile, starts_on: monday, ends_on: monday)

      assert {:ok, []} = slots(monday, default_schedule)
      assert {:ok, []} = slots(monday, second)
    end
  end

  describe "part-day time off" do
    test "carves its window out of the day and leaves the rest bookable" do
      {profile, schedule, monday} = weekday_schedule()

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: monday,
        start_time: ~T[13:00:00],
        end_time: ~T[17:00:00]
      )

      assert {:ok, slots} = slots(monday, schedule)

      assert "9:00 AM" in slots
      assert "12:30 PM" in slots
      refute "1:00 PM" in slots
      refute "3:00 PM" in slots
      refute "4:30 PM" in slots
    end

    test "blocks a slot that would run into the window rather than only those starting inside it" do
      {profile, schedule, monday} = weekday_schedule()

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: monday,
        start_time: ~T[12:30:00],
        end_time: ~T[17:00:00]
      )

      assert {:ok, slots} =
               Calculate.available_slots(monday, 60, @timezone, @timezone, [], config(schedule))

      # The grid is duration-locked from 09:00, so the hourly starts are the
      # only ones on offer. 11:00 finishes at noon and survives; 12:00 is still
      # running at 12:30 and must go, even though it starts before the window.
      assert "11:00 AM" in slots
      refute "12:00 PM" in slots
    end

    test "trims only the edge days of a multi-day period" do
      {profile, schedule, monday} = weekday_schedule()
      wednesday = Date.add(monday, 2)

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: wednesday,
        start_time: ~T[13:00:00],
        end_time: ~T[11:00:00]
      )

      {:ok, first_day} = slots(monday, schedule)
      assert "9:00 AM" in first_day
      refute "1:00 PM" in first_day

      assert {:ok, []} = slots(Date.add(monday, 1), schedule)

      {:ok, last_day} = slots(wednesday, schedule)
      refute "9:00 AM" in last_day
      assert "11:00 AM" in last_day
    end

    test "leaves the day on the calendar grid when slots survive around it" do
      {profile, schedule, monday} = weekday_schedule()

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: monday,
        start_time: ~T[13:00:00],
        end_time: ~T[17:00:00]
      )

      assert BusinessHours.business_day?(monday, schedule.id, %{})

      assert {:ok, availability} =
               Calculate.range_availability(
                 monday,
                 monday,
                 @timezone,
                 @timezone,
                 [],
                 config(schedule)
               )

      assert availability[Date.to_string(monday)]
    end
  end

  # --- Helpers ---

  # A Berlin profile whose default schedule is available 09:00-17:00 on the
  # next Monday, Tuesday and Wednesday. Returns `{profile, schedule, monday}`.
  defp weekday_schedule do
    monday = next_weekday(1)
    profile = insert(:profile, timezone: @timezone)

    schedule =
      insert(:availability_schedule, profile: profile, is_default: true, buffer_minutes: 0)

    for day_of_week <- 1..3 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    {profile, schedule, monday}
  end

  # A Berlin profile whose default schedule marks Saturday unavailable, so an
  # `available` override is the only thing that can open the day.
  defp unavailable_saturday_schedule do
    saturday = next_weekday(6)
    profile = insert(:profile, timezone: @timezone)

    schedule =
      insert(:availability_schedule, profile: profile, is_default: true, buffer_minutes: 0)

    insert(:weekly_availability, schedule: schedule, day_of_week: 6, is_available: false)

    {profile, schedule, saturday}
  end

  defp next_weekday(target_dow) when target_dow in 1..7 do
    today = Date.utc_today()
    days_ahead = rem(target_dow - Date.day_of_week(today) + 7, 7)
    Date.add(today, if(days_ahead == 0, do: 7, else: days_ahead))
  end

  defp slots(date, schedule) do
    Calculate.available_slots(date, 30, @timezone, @timezone, [], config(schedule))
  end

  defp config(schedule) do
    %{schedule_id: schedule.id, buffer_minutes: 0, min_advance_hours: 0}
  end
end
