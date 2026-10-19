defmodule Tymeslot.Availability.StaleBreaksTest do
  @moduledoc """
  A break that falls outside its day's hours: refused when narrowing the hours
  would create one, and named, with nothing written, when an old one blocks a
  copy.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :availability

  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule

  setup do
    # Monday 09:00-17:00 (create_profile_with_day/0)
    %{schedule: schedule, day: day} = create_profile_with_day()
    %{schedule: schedule, day: day}
  end

  describe "narrowing a day's hours" do
    test "is refused when a break would fall outside, naming it", %{schedule: schedule, day: day} do
      {:ok, late} = Breaks.add_break(day.id, ~T[16:00:00], ~T[16:30:00], "Late")

      assert {:error, {:breaks_outside_hours, [%{id: id}]}} =
               AvailabilityActions.update_day_hours(
                 schedule.profile_id,
                 schedule.id,
                 1,
                 "09:00",
                 "12:00"
               )

      assert id == late.id

      assert %{start_time: ~T[09:00:00], end_time: ~T[17:00:00]} =
               WeeklySchedule.get_day_availability(schedule.id, 1)
    end

    test "is refused for a break across midnight when the hours stop running past it", %{
      schedule: schedule
    } do
      {:ok, night} =
        AvailabilityActions.update_day_hours(
          schedule.profile_id,
          schedule.id,
          1,
          "22:00",
          "02:00+1"
        )

      {:ok, _late} = Breaks.add_break(night.id, ~T[23:00:00], ~T[00:00:00], "Tea")

      assert {:error, {:breaks_outside_hours, [%{start_time: ~T[23:00:00]}]}} =
               AvailabilityActions.update_day_hours(
                 schedule.profile_id,
                 schedule.id,
                 1,
                 "09:00",
                 "17:00"
               )
    end

    test "is allowed when every break still fits", %{schedule: schedule, day: day} do
      {:ok, _lunch} = Breaks.add_break(day.id, ~T[11:00:00], ~T[11:30:00], "Lunch")

      assert {:ok, %{end_time: ~T[12:00:00]}} =
               AvailabilityActions.update_day_hours(
                 schedule.profile_id,
                 schedule.id,
                 1,
                 "09:00",
                 "12:00"
               )
    end
  end

  describe "copying a day" do
    test "copies its breaks with its hours", %{schedule: schedule, day: day} do
      {:ok, _lunch} = Breaks.add_break(day.id, ~T[12:00:00], ~T[12:30:00], "Lunch")

      assert {:ok, _result} =
               AvailabilityActions.copy_day_settings(schedule.profile_id, schedule.id, 1, [2, 3])

      for target <- [2, 3] do
        assert [%{start_time: ~T[12:00:00], label: "Lunch"}] =
                 WeeklySchedule.get_day_availability(schedule.id, target).breaks
      end
    end

    # A break saved before Monday's hours were narrowed (the narrowing is
    # refused now, but rows from before stay).
    test "stops at a stale break, names it, and writes no target day", %{
      schedule: schedule,
      day: day
    } do
      stale =
        insert(:availability_break,
          weekly_availability: day,
          start_time: ~T[18:00:00],
          end_time: ~T[18:30:00]
        )

      assert {:error, {:break_outside_hours, %{day_of_week: 1}, %{id: id}}} =
               AvailabilityActions.copy_day_settings(schedule.profile_id, schedule.id, 1, [2, 3])

      assert id == stale.id
      # Tuesday's hours were written before its breaks were refused: rolled back.
      assert WeeklySchedule.get_day_availability(schedule.id, 2) == nil
      assert WeeklySchedule.get_day_availability(schedule.id, 3) == nil
    end
  end

  describe "duplicating a schedule" do
    test "stops at a stale break, names it, and leaves no partial copy", %{
      schedule: schedule,
      day: day
    } do
      insert(:availability_break,
        weekly_availability: day,
        start_time: ~T[18:00:00],
        end_time: ~T[18:30:00]
      )

      count = Repo.aggregate(AvailabilityScheduleSchema, :count)

      assert {:error, {:break_outside_hours, %{day_of_week: 1}, %{start_time: ~T[18:00:00]}}} =
               Schedules.duplicate(schedule)

      assert Repo.aggregate(AvailabilityScheduleSchema, :count) == count
    end
  end
end
