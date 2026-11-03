defmodule Tymeslot.Availability.SetWeeklyHoursTest do
  @moduledoc """
  `Availability.set_weekly_hours/2` and `weekly_hours/1`: the host's week as
  one window over a set of days, written to the default schedule all at
  once or not at all.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability

  import Tymeslot.Factory

  alias Tymeslot.Availability
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
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
             end: "12:00"
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
end
