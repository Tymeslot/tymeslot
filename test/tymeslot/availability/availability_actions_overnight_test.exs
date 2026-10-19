defmodule Tymeslot.Availability.AvailabilityActionsOvernightTest do
  use Tymeslot.DataCase, async: true
  @moduletag :availability

  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.WeeklySchedule

  describe "hours that end the next day" do
    setup do
      %{schedule: schedule} = create_profile_with_day()
      %{schedule: schedule}
    end

    test "update_day_hours/4 stores the flag from the editor's end value", %{schedule: schedule} do
      assert {:ok, day} =
               AvailabilityActions.update_day_hours(
                 schedule.profile_id,
                 schedule.id,
                 1,
                 "22:00",
                 "02:00+1"
               )

      assert {day.start_time, day.end_time, day.ends_next_day} ==
               {~T[22:00:00], ~T[02:00:00], true}

      assert {:ok, day} =
               AvailabilityActions.update_day_hours(
                 schedule.profile_id,
                 schedule.id,
                 1,
                 "09:00",
                 "17:00"
               )

      refute day.ends_next_day
    end

    test "switching a day on gives it same-day default hours", %{schedule: schedule} do
      {:ok, _result} =
        AvailabilityActions.update_day_hours(
          schedule.profile_id,
          schedule.id,
          3,
          "22:00",
          "02:00+1"
        )

      {:ok, _result} =
        AvailabilityActions.toggle_day_availability(schedule.profile_id, schedule.id, 3, true)

      assert {:ok, day} =
               AvailabilityActions.toggle_day_availability(
                 schedule.profile_id,
                 schedule.id,
                 3,
                 false
               )

      assert day.is_available
      refute day.ends_next_day
    end

    test "copying a day copies the flag and the breaks after midnight", %{schedule: schedule} do
      {:ok, night} =
        AvailabilityActions.update_day_hours(
          schedule.profile_id,
          schedule.id,
          5,
          "22:00",
          "04:00+1"
        )

      {:ok, _break} = Breaks.add_break(night.id, ~T[01:00:00], ~T[01:30:00], "Tea")

      assert {:ok, _result} =
               AvailabilityActions.copy_day_settings(schedule.profile_id, schedule.id, 5, [6])

      copy = WeeklySchedule.get_day_availability(schedule.id, 6)
      assert {copy.end_time, copy.ends_next_day} == {~T[04:00:00], true}
      assert [%{start_time: ~T[01:00:00], end_time: ~T[01:30:00]}] = copy.breaks
    end

    test "clearing a day resets the flag", %{schedule: schedule} do
      {:ok, _result} =
        AvailabilityActions.update_day_hours(
          schedule.profile_id,
          schedule.id,
          2,
          "22:00",
          "02:00+1"
        )

      assert {:ok, day} =
               AvailabilityActions.clear_day_settings(schedule.profile_id, schedule.id, 2)

      refute day.ends_next_day
    end
  end
end
