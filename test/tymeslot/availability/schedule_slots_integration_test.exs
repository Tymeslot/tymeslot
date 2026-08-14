defmodule Tymeslot.Availability.ScheduleSlotsIntegrationTest do
  @moduledoc """
  The user-level guarantee of per-meeting-type availability: two meeting types
  on two different schedules offer different slots, their breaks and date
  overrides are independent, and booking-time validation resolves the same
  schedule the offered slots were computed from.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Bookings.Policy

  # A Wednesday, far enough ahead that minimum notice never trims the day.
  @date ~D[2026-09-16]

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, timezone: "Etc/UTC")

    {:ok, mornings} = Schedules.create_default(profile.id)
    {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})

    set_hours(mornings.id, ~T[09:00:00], ~T[12:00:00])
    set_hours(evenings.id, ~T[18:00:00], ~T[21:00:00])

    morning_type =
      insert(:meeting_type, user: user, duration_minutes: 60, availability_schedule_id: nil)

    evening_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 60,
        availability_schedule_id: evenings.id
      )

    {:ok,
     user: user,
     profile: profile,
     mornings: mornings,
     evenings: evenings,
     morning_type: morning_type,
     evening_type: evening_type}
  end

  defp set_hours(schedule_id, start_time, end_time) do
    Enum.each(1..5, fn day ->
      {:ok, _row} =
        WeeklySchedule.upsert_day_availability(schedule_id, day, %{
          is_available: true,
          start_time: start_time,
          end_time: end_time
        })
    end)

    Enum.each(6..7, fn day ->
      {:ok, _row} =
        WeeklySchedule.upsert_day_availability(schedule_id, day, %{is_available: false})
    end)
  end

  defp slots_for(schedule, duration_minutes) do
    config = %{
      schedule_id: schedule.id,
      buffer_minutes: schedule.buffer_minutes,
      min_advance_hours: 0,
      max_advance_booking_days: 3650,
      duration_minutes: duration_minutes
    }

    {:ok, slots} =
      Calculate.available_slots(@date, duration_minutes, "Etc/UTC", "Etc/UTC", [], config)

    slots
  end

  defp slot_times(slots), do: Enum.map(slots, &TimeSlots.parse_time_slot/1)

  test "each meeting type offers slots from its own schedule", %{
    mornings: mornings,
    evenings: evenings
  } do
    morning_slots = slots_for(mornings, 60)
    evening_slots = slots_for(evenings, 60)

    refute morning_slots == []
    refute evening_slots == []
    assert MapSet.disjoint?(MapSet.new(morning_slots), MapSet.new(evening_slots))

    assert Enum.all?(slot_times(morning_slots), &(Time.compare(&1, ~T[12:00:00]) != :gt))
    assert Enum.all?(slot_times(evening_slots), &(Time.compare(&1, ~T[17:00:00]) == :gt))
  end

  test "a break on one schedule does not remove slots from the other", %{
    mornings: mornings,
    evenings: evenings
  } do
    wednesday = WeeklySchedule.get_day_availability(evenings.id, 3)

    {:ok, _break} = Breaks.add_break(wednesday.id, ~T[19:00:00], ~T[20:00:00], "Dinner")

    evening_times = slot_times(slots_for(evenings, 60))
    morning_times = slot_times(slots_for(mornings, 60))

    refute Enum.any?(evening_times, &(Time.compare(&1, ~T[19:00:00]) == :eq))
    refute morning_times == []
  end

  test "an override on one schedule closes only that schedule's day", %{
    mornings: mornings,
    evenings: evenings
  } do
    {:ok, _override} =
      AvailabilityOverrideQueries.create_override(%{
        schedule_id: evenings.id,
        date: @date,
        override_type: "unavailable",
        reason: "Closed"
      })

    assert slots_for(evenings, 60) == []
    refute slots_for(mornings, 60) == []
  end

  test "booking-time policy resolves the same schedule as slot computation", %{
    user: user,
    evenings: evenings,
    evening_type: evening_type,
    morning_type: morning_type
  } do
    {:ok, evenings} =
      Schedules.update_policy(evenings, %{buffer_minutes: 45, min_advance_hours: 72})

    evening_config = Policy.scheduling_config(user.id, evening_type)
    morning_config = Policy.scheduling_config(user.id, morning_type)

    assert evenings.buffer_minutes == 45
    assert evening_config.buffer_minutes == 45
    assert evening_config.min_advance_hours == 72

    refute morning_config.buffer_minutes == 45
    refute morning_config.min_advance_hours == 72
  end
end
