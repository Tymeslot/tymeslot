defmodule Tymeslot.Availability.AvailabilityActionsTest do
  @moduledoc """
  Comprehensive behavior tests for the Availability management functionality.
  Focuses on user-facing functionality and business rules.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :availability

  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.WeeklySchedule
  import Tymeslot.AvailabilityTestHelpers

  # =====================================
  # Weekly Schedule Management Behaviors
  # =====================================

  describe "when setting up weekly availability" do
    test "ensures complete schedule exists with all 7 days" do
      schedule = insert(:availability_schedule)

      # Create only Monday (day 1) with required times
      {:ok, monday} =
        WeeklySchedule.create_day_availability(schedule.id, 1, %{
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        })

      # Pass the existing days (list of day records), not the schedule
      existing_days = [monday]
      complete = AvailabilityActions.ensure_complete_schedule(existing_days, schedule.id)

      # Should have all 7 days after ensuring complete schedule
      days = Enum.map(complete, & &1.day_of_week)
      assert Enum.sort(days) == [1, 2, 3, 4, 5, 6, 7]
    end

    test "creates default unavailable days for missing days" do
      schedule = insert(:availability_schedule)

      # Create only weekdays with required times
      for day <- 1..5 do
        {:ok, _result} =
          WeeklySchedule.create_day_availability(schedule.id, day, %{
            is_available: true,
            start_time: ~T[09:00:00],
            end_time: ~T[17:00:00]
          })
      end

      existing_days = WeeklySchedule.get_weekly_schedule(schedule.id)
      complete = AvailabilityActions.ensure_complete_schedule(existing_days, schedule.id)

      # Weekend days should now exist
      assert %{is_available: false} = Enum.find(complete, &(&1.day_of_week == 6))
      assert %{is_available: false} = Enum.find(complete, &(&1.day_of_week == 7))
    end

    test "is idempotent when all 7 days already exist" do
      schedule = insert(:availability_schedule)

      # Create all 7 days
      for day <- 1..7 do
        {:ok, _day} =
          WeeklySchedule.create_day_availability(schedule.id, day, %{
            is_available: day in 1..5,
            start_time: if(day in 1..5, do: ~T[09:00:00]),
            end_time: if(day in 1..5, do: ~T[17:00:00])
          })
      end

      existing_days = WeeklySchedule.get_weekly_schedule(schedule.id)
      assert length(existing_days) == 7

      complete = AvailabilityActions.ensure_complete_schedule(existing_days, schedule.id)
      assert length(complete) == 7
      # Verify no duplicates
      days = Enum.map(complete, & &1.day_of_week)
      assert Enum.sort(days) == [1, 2, 3, 4, 5, 6, 7]
    end
  end

  describe "when toggling day availability" do
    setup do
      %{schedule: schedule, day: day} = create_profile_with_day()
      %{schedule: schedule, day: day}
    end

    test "makes available day unavailable", %{schedule: schedule} do
      assert {:ok, _result} = AvailabilityActions.toggle_day_availability(schedule.id, 1, true)

      updated = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert updated.is_available == false
    end

    test "makes unavailable day available with default hours", %{schedule: schedule} do
      # First make day unavailable
      {:ok, _result} = AvailabilityActions.toggle_day_availability(schedule.id, 1, true)

      # Then toggle back to available
      assert {:ok, _result} = AvailabilityActions.toggle_day_availability(schedule.id, 1, false)

      updated = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert updated.is_available == true
      assert updated.start_time == ~T[11:00:00]
      assert updated.end_time == ~T[19:30:00]
    end

    test "creates day when toggling a day that doesn't exist yet", %{schedule: schedule} do
      # Day 3 (Wednesday) doesn't exist — toggle should create it via upsert
      assert {:ok, _result} = AvailabilityActions.toggle_day_availability(schedule.id, 3, false)

      assert %{
               is_available: true,
               start_time: ~T[11:00:00],
               end_time: ~T[19:30:00]
             } = WeeklySchedule.get_day_availability(schedule.id, 3)
    end
  end

  describe "when updating day hours" do
    setup do
      %{schedule: schedule, day: day} = create_profile_with_day()
      %{schedule: schedule, day: day}
    end

    test "updates hours with valid time strings", %{schedule: schedule} do
      assert {:ok, _result} =
               AvailabilityActions.update_day_hours(schedule.id, 1, "08:00", "18:00")

      updated = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert updated.start_time == ~T[08:00:00]
      assert updated.end_time == ~T[18:00:00]
    end

    test "returns error for invalid time format", %{schedule: schedule} do
      result = AvailabilityActions.update_day_hours(schedule.id, 1, "invalid", "18:00")

      assert {:error, :invalid_time_format} = result
    end

    test "accepts early morning start times", %{schedule: schedule} do
      assert {:ok, _result} =
               AvailabilityActions.update_day_hours(schedule.id, 1, "06:00", "14:00")

      updated = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert updated.start_time == ~T[06:00:00]
    end

    test "accepts late evening end times", %{schedule: schedule} do
      assert {:ok, _result} =
               AvailabilityActions.update_day_hours(schedule.id, 1, "12:00", "22:00")

      updated = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert updated.end_time == ~T[22:00:00]
    end
  end

  # =====================================
  # Break Management Behaviors
  # =====================================

  describe "when adding a break to availability" do
    setup do
      %{schedule: schedule, day: day} = create_profile_with_day()
      %{schedule: schedule, day: day}
    end

    test "adds break with valid times", %{day: day} do
      assert {:ok, break} = AvailabilityActions.add_break(day.id, "12:00", "13:00", "Lunch")

      assert break.start_time == ~T[12:00:00]
      assert break.end_time == ~T[13:00:00]
      assert break.label == "Lunch"
    end

    test "adds break without label", %{day: day} do
      assert {:ok, break} = AvailabilityActions.add_break(day.id, "15:00", "15:30", "")

      assert break.start_time == ~T[15:00:00]
      assert break.label == nil
    end

    test "returns error for invalid time format", %{day: day} do
      result = AvailabilityActions.add_break(day.id, "invalid", "13:00", "Break")

      assert {:error, :invalid_time_format} = result
    end
  end

  describe "when adding overlapping breaks" do
    setup do
      %{schedule: schedule, day: day} = create_profile_with_day()
      # Add a break from 12:00 to 13:00
      {:ok, _break} = Breaks.add_break(day.id, ~T[12:00:00], ~T[13:00:00], "Lunch")
      %{schedule: schedule, day: day}
    end

    test "rejects break that overlaps with existing break", %{day: day} do
      result = AvailabilityActions.add_break(day.id, "12:30", "13:30", "Overlap")
      assert {:error, changeset} = result
      assert %Ecto.Changeset{} = changeset
    end

    test "allows adjacent non-overlapping breaks", %{day: day} do
      assert {:ok, break} = AvailabilityActions.add_break(day.id, "13:00", "14:00", "After Lunch")
      assert break.start_time == ~T[13:00:00]
      assert break.end_time == ~T[14:00:00]
    end
  end

  describe "when adding a quick break" do
    setup do
      %{schedule: schedule, day: day} = create_profile_with_day()
      %{schedule: schedule, day: day}
    end

    test "creates break with specified duration", %{day: day} do
      # 30 minute break starting at 12:00
      assert {:ok, break} = AvailabilityActions.add_quick_break(day.id, "12:00", 30)

      assert break.start_time == ~T[12:00:00]
      assert break.end_time == ~T[12:30:00]
    end

    test "creates 15 minute break", %{day: day} do
      assert {:ok, break} = AvailabilityActions.add_quick_break(day.id, "14:00", 15)

      assert break.start_time == ~T[14:00:00]
      assert break.end_time == ~T[14:15:00]
    end

    test "creates 60 minute break", %{day: day} do
      assert {:ok, break} = AvailabilityActions.add_quick_break(day.id, "12:00", 60)

      assert break.start_time == ~T[12:00:00]
      assert break.end_time == ~T[13:00:00]
    end

    test "returns error for invalid time format", %{day: day} do
      result = AvailabilityActions.add_quick_break(day.id, "not-a-time", 30)

      assert {:error, :invalid_time_format} = result
    end

    test "returns clear error when duration wraps past midnight", %{day: day} do
      # 480 min (8h) starting at 20:00 wraps to 04:00 next day
      result = AvailabilityActions.add_quick_break(day.id, "20:00", 480)

      assert {:error, "Break duration extends past end of day"} = result
    end
  end

  describe "when deleting a break" do
    setup do
      %{schedule: schedule, day: day} = create_profile_with_day()

      {:ok, break} = Breaks.add_break(day.id, ~T[12:00:00], ~T[13:00:00], "Lunch")

      %{schedule: schedule, day: day, break: break}
    end

    test "successfully deletes existing break", %{schedule: schedule, day: day, break: break} do
      assert {:ok, _deleted} = AvailabilityActions.delete_break(break.id, schedule.id)

      breaks = Breaks.get_breaks_for_day(day.id)
      assert breaks == []
    end

    test "returns error for non-existent break", %{schedule: schedule} do
      result = AvailabilityActions.delete_break(999_999, schedule.id)

      assert {:error, "Break not found"} = result
    end

    test "prevents deleting another user's break" do
      # Create a second user with a break
      other_schedule = insert(:availability_schedule)

      {:ok, other_day} =
        WeeklySchedule.create_day_availability(other_schedule.id, 1, %{
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        })

      {:ok, other_break} = Breaks.add_break(other_day.id, ~T[12:00:00], ~T[13:00:00], "Lunch")

      # Try to delete with a schedule that does not own the break
      my_schedule = insert(:availability_schedule)

      result = AvailabilityActions.delete_break(other_break.id, my_schedule.id)
      assert {:error, "Unauthorized"} = result

      # Verify break still exists
      breaks = Breaks.get_breaks_for_day(other_day.id)
      assert length(breaks) == 1
    end

    test "allows deleting own break with schedule_id" do
      schedule = insert(:availability_schedule)

      {:ok, day} =
        WeeklySchedule.create_day_availability(schedule.id, 1, %{
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        })

      {:ok, break} = Breaks.add_break(day.id, ~T[12:00:00], ~T[13:00:00], "Lunch")

      assert {:ok, _deleted} = AvailabilityActions.delete_break(break.id, schedule.id)

      breaks = Breaks.get_breaks_for_day(day.id)
      assert breaks == []
    end
  end

  # =====================================
  # Bulk Operations Behaviors
  # =====================================

  describe "when copying day settings" do
    setup do
      schedule = insert(:availability_schedule)

      # Create Monday with specific settings
      {:ok, monday} =
        WeeklySchedule.create_day_availability(schedule.id, 1, %{
          is_available: true,
          start_time: ~T[08:00:00],
          end_time: ~T[16:00:00]
        })

      %{schedule: schedule, monday: monday}
    end

    test "copies settings from one day to multiple days", %{schedule: schedule} do
      # Copy Monday settings to Tuesday, Wednesday
      assert {:ok, _result} = AvailabilityActions.copy_day_settings(schedule.id, 1, [2, 3])

      tuesday = WeeklySchedule.get_day_availability(schedule.id, 2)
      wednesday = WeeklySchedule.get_day_availability(schedule.id, 3)

      assert tuesday.is_available == true
      assert tuesday.start_time == ~T[08:00:00]
      assert tuesday.end_time == ~T[16:00:00]

      assert wednesday.is_available == true
      assert wednesday.start_time == ~T[08:00:00]
    end

    test "returns error when source day not found", %{schedule: schedule} do
      # Sunday (7) doesn't exist yet
      result = AvailabilityActions.copy_day_settings(schedule.id, 7, [2, 3])

      assert {:error, "Source day not found"} = result
    end
  end

  describe "when applying preset schedules" do
    setup do
      schedule = insert(:availability_schedule)
      %{schedule: schedule}
    end

    test "applies 9-5 workday preset", %{schedule: schedule} do
      assert {:ok, _result} = AvailabilityActions.apply_preset(schedule.id, "9-5", [1, 2, 3])

      monday = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert monday.is_available == true
      assert monday.start_time == ~T[09:00:00]
      assert monday.end_time == ~T[17:00:00]
    end

    test "applies 8-6 preset", %{schedule: schedule} do
      assert {:ok, _result} = AvailabilityActions.apply_preset(schedule.id, "8-6", [1])

      monday = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert monday.start_time == ~T[08:00:00]
      assert monday.end_time == ~T[18:00:00]
    end

    test "applies 10-6 preset", %{schedule: schedule} do
      assert {:ok, _result} = AvailabilityActions.apply_preset(schedule.id, "10-6", [1])

      monday = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert monday.start_time == ~T[10:00:00]
      assert monday.end_time == ~T[18:00:00]
    end

    test "applies unavailable preset", %{schedule: schedule} do
      assert {:ok, _result} = AvailabilityActions.apply_preset(schedule.id, "unavailable", [1])

      monday = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert monday.is_available == false
    end

    test "returns error for unknown preset", %{schedule: schedule} do
      result = AvailabilityActions.apply_preset(schedule.id, "nonexistent", [1])

      assert {:error, message} = result
      assert message =~ "Unknown preset"
    end
  end

  describe "when clearing day settings" do
    setup do
      %{schedule: schedule, day: day} = create_profile_with_day()

      # Add some breaks
      {:ok, _break} = Breaks.add_break(day.id, ~T[12:00:00], ~T[13:00:00], "Lunch")

      %{schedule: schedule, day: day}
    end

    test "sets day to unavailable and clears breaks", %{schedule: schedule, day: day} do
      assert {:ok, _result} = AvailabilityActions.clear_day_settings(schedule.id, 1)

      updated = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert updated.is_available == false

      breaks = Breaks.get_breaks_for_day(day.id)
      assert breaks == []
    end

    test "succeeds when day has no breaks" do
      schedule = insert(:availability_schedule)

      {:ok, _day} =
        WeeklySchedule.create_day_availability(schedule.id, 1, %{
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        })

      assert {:ok, _result} = AvailabilityActions.clear_day_settings(schedule.id, 1)

      updated = WeeklySchedule.get_day_availability(schedule.id, 1)
      assert updated.is_available == false
    end
  end

  # =====================================
  # Helper Function Behaviors
  # =====================================

  describe "when finding day from schedule" do
    test "returns correct day" do
      schedule = [
        %{day_of_week: 1, is_available: true},
        %{day_of_week: 2, is_available: false},
        %{day_of_week: 3, is_available: true}
      ]

      result = AvailabilityActions.get_day_from_schedule(schedule, 2)

      assert result.day_of_week == 2
      assert result.is_available == false
    end

    test "returns nil when day not in schedule" do
      schedule = [
        %{day_of_week: 1, is_available: true},
        %{day_of_week: 2, is_available: false}
      ]

      result = AvailabilityActions.get_day_from_schedule(schedule, 5)

      assert result == nil
    end
  end

  describe "when getting day names" do
    test "returns correct name for each day" do
      assert AvailabilityActions.day_name(1) == "Monday"
      assert AvailabilityActions.day_name(2) == "Tuesday"
      assert AvailabilityActions.day_name(3) == "Wednesday"
      assert AvailabilityActions.day_name(4) == "Thursday"
      assert AvailabilityActions.day_name(5) == "Friday"
      assert AvailabilityActions.day_name(6) == "Saturday"
      assert AvailabilityActions.day_name(7) == "Sunday"
    end
  end

  describe "when getting day name for invalid day" do
    test "returns Unknown for out-of-range day" do
      assert AvailabilityActions.day_name(0) == "Unknown"
      assert AvailabilityActions.day_name(8) == "Unknown"
    end
  end

  describe "when formatting changeset errors" do
    test "formats start_time error" do
      changeset = %Ecto.Changeset{
        errors: [{:start_time, {"must be before end time", []}}],
        valid?: false
      }

      result = AvailabilityActions.format_changeset_error(changeset)

      assert result =~ "Start time"
      assert result =~ "must be before end time"
    end

    test "formats end_time error" do
      changeset = %Ecto.Changeset{
        errors: [{:end_time, {"is invalid", []}}],
        valid?: false
      }

      result = AvailabilityActions.format_changeset_error(changeset)

      assert result =~ "End time"
      assert result =~ "is invalid"
    end

    test "returns default message for non-changeset" do
      result = AvailabilityActions.format_changeset_error("some error")

      assert result == "An error occurred"
    end
  end
end
