defmodule Tymeslot.Availability.SetWeeklyHoursTest do
  @moduledoc """
  `Availability.set_weekly_hours/2` and `weekly_hours/1`: the host's week as
  one window over a set of days, written to the default schedule all at
  once or not at all.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability

  import Tymeslot.Factory

  alias Tymeslot.Availability
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles

  setup do
    user = insert(:user)
    {:ok, profile} = Profiles.create_profile(user.id)
    %{profile: profile, schedule: Schedules.get_default(profile.id)}
  end

  defp week(schedule) do
    schedule.id
    |> WeeklySchedule.get_weekly_schedule()
    |> Map.new(fn day -> {day.day_of_week, {day.is_available, day.start_time, day.end_time}} end)
  end

  test "writes the window to the chosen days and turns the rest off", %{
    profile: profile,
    schedule: schedule
  } do
    assert :ok =
             Availability.set_weekly_hours(profile.id, %{
               days: [2, 4, 6],
               start: "08:30",
               end: "12:00"
             })

    week = week(schedule)
    assert Enum.map([2, 4, 6], &week[&1]) == List.duplicate({true, ~T[08:30:00], ~T[12:00:00]}, 3)
    assert Enum.map([1, 3, 5, 7], &elem(week[&1], 0)) == [false, false, false, false]

    assert Availability.weekly_hours(profile.id) == %{
             days: [2, 4, 6],
             start: "08:30",
             end: "12:00",
             uniform: true
           }
  end

  test "refuses an empty day list and changes nothing", %{profile: profile, schedule: schedule} do
    before = week(schedule)

    assert {:error, :no_days} =
             Availability.set_weekly_hours(profile.id, %{days: [], start: "09:00", end: "17:00"})

    assert week(schedule) == before
  end

  test "refuses an end before the start and changes nothing", %{
    profile: profile,
    schedule: schedule
  } do
    before = week(schedule)

    assert {:error, :end_before_start} =
             Availability.set_weekly_hours(profile.id, %{
               days: [1, 2],
               start: "17:00",
               end: "09:00"
             })

    assert week(schedule) == before
  end

  test "a day refused partway leaves the whole week as it was", %{
    profile: profile,
    schedule: schedule
  } do
    # Friday has a break the new window would strand; Monday comes first.
    friday = WeeklySchedule.get_day_availability(schedule.id, 5)
    {:ok, _break} = Breaks.add_break(friday.id, ~T[15:00:00], ~T[15:30:00], nil)
    before = week(schedule)

    assert {:error, {:breaks_outside_hours, [_break]}} =
             Availability.set_weekly_hours(profile.id, %{
               days: [1, 2, 3, 4, 5],
               start: "08:00",
               end: "12:00"
             })

    assert week(schedule) == before
  end

  test "refuses a day that is not an ISO weekday", %{profile: profile, schedule: schedule} do
    before = week(schedule)

    assert {:error, :invalid_day} =
             Availability.set_weekly_hours(profile.id, %{
               days: [1, 8],
               start: "09:00",
               end: "17:00"
             })

    assert week(schedule) == before
  end

  test "a profile without a default schedule has no week to read or write" do
    profile = insert(:profile)

    assert Availability.weekly_hours(profile.id) == nil

    assert {:error, :no_schedule} =
             Availability.set_weekly_hours(profile.id, %{days: [1], start: "09:00", end: "17:00"})
  end

  test "turning a day off clears its breaks", %{profile: profile, schedule: schedule} do
    friday = WeeklySchedule.get_day_availability(schedule.id, 5)
    {:ok, _break} = Breaks.add_break(friday.id, ~T[12:00:00], ~T[12:30:00], nil)

    assert :ok =
             Availability.set_weekly_hours(profile.id, %{days: [1], start: "09:00", end: "17:00"})

    assert %{is_available: false, breaks: []} =
             WeeklySchedule.get_day_availability(schedule.id, 5)
  end

  test "a week whose days differ reads as not uniform", %{profile: profile, schedule: schedule} do
    {:ok, _day} =
      WeeklySchedule.upsert_day_availability(schedule.id, 2, %{
        is_available: true,
        start_time: ~T[10:00:00],
        end_time: ~T[16:00:00]
      })

    assert %{days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00", uniform: false} =
             Availability.weekly_hours(profile.id)
  end

  test "keeps the cached calendar events and clears the cached ranges", %{
    profile: profile
  } do
    AvailabilityCache.clear_all()
    events_key = AvailabilityCache.booking_window_events_key(profile.user_id)

    range_key =
      AvailabilityCache.availability_range_key(
        profile.user_id,
        ~D[2026-11-02],
        ~D[2026-11-08],
        "Etc/UTC",
        30,
        nil,
        nil
      )

    {:ok, [:cached]} =
      AvailabilityCache.get_or_compute_events(events_key, fn -> {:ok, [:cached]} end)

    :cached_range = AvailabilityCache.get_or_compute(range_key, fn -> :cached_range end)

    assert :ok =
             Availability.set_weekly_hours(profile.id, %{days: [1], start: "09:00", end: "12:00"})

    assert {:ok, [:cached]} =
             AvailabilityCache.get_or_compute_events(events_key, fn -> {:ok, [:fresh]} end)

    assert :fresh_range = AvailabilityCache.get_or_compute(range_key, fn -> :fresh_range end)
  end
end
