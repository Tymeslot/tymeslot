defmodule Tymeslot.Availability.AvailabilityActionsTest do
  @moduledoc """
  Comprehensive behavior tests for the Availability management functionality.
  Focuses on user-facing functionality and business rules.
  """

  use Tymeslot.DataCase, async: true

  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.WeeklySchedule
  import Tymeslot.AvailabilityTestHelpers

  # =====================================
  # Weekly Schedule Management Behaviors
  # =====================================

  describe "when setting up weekly availability" do
    test "ensures complete schedule exists with all 7 days" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      # Create only Monday (day 1) with required times
      {:ok, monday} =
        WeeklySchedule.create_day_availability(profile.id, 1, %{
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        })

      # Pass the existing schedule (list of day records), not the profile
      existing_schedule = [monday]
      schedule = AvailabilityActions.ensure_complete_schedule(existing_schedule, profile.id)

      # Should have all 7 days after ensuring complete schedule
      days = Enum.map(schedule, & &1.day_of_week)
      assert Enum.sort(days) == [1, 2, 3, 4, 5, 6, 7]
    end

    test "creates default unavailable days for missing days" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      # Create only weekdays with required times
      for day <- 1..5 do
        {:ok, _} =
          WeeklySchedule.create_day_availability(profile.id, day, %{
            is_available: true,
            start_time: ~T[09:00:00],
            end_time: ~T[17:00:00]
          })
      end

      existing_schedule = WeeklySchedule.get_weekly_schedule(profile.id)
      schedule = AvailabilityActions.ensure_complete_schedule(existing_schedule, profile.id)

      # Weekend days should now exist
      saturday = Enum.find(schedule, &(&1.day_of_week == 6))
      sunday = Enum.find(schedule, &(&1.day_of_week == 7))

      assert saturday != nil
      assert sunday != nil
      assert saturday.is_available == false
      assert sunday.is_available == false
    end
  end

  describe "when toggling day availability" do
    setup do
      %{profile: profile, day: day} = create_profile_with_day()
      %{profile: profile, day: day}
    end

    test "makes available day unavailable", %{profile: profile} do
      assert {:ok, _result} = AvailabilityActions.toggle_day_availability(profile.id, 1, true)

      updated = WeeklySchedule.get_day_availability(profile.id, 1)
      assert updated.is_available == false
    end

    test "makes unavailable day available with default hours", %{profile: profile} do
      # First make day unavailable
      {:ok, _} = AvailabilityActions.toggle_day_availability(profile.id, 1, true)

      # Then toggle back to available
      assert {:ok, _result} = AvailabilityActions.toggle_day_availability(profile.id, 1, false)

      updated = WeeklySchedule.get_day_availability(profile.id, 1)
      assert updated.is_available == true
      assert updated.start_time == ~T[11:00:00]
      assert updated.end_time == ~T[19:30:00]
    end
  end

  describe "when updating day hours" do
    setup do
      %{profile: profile, day: day} = create_profile_with_day()
      %{profile: profile, day: day}
    end

    test "updates hours with valid time strings", %{profile: profile} do
      assert {:ok, _result} = AvailabilityActions.update_day_hours(profile.id, 1, "08:00", "18:00")

      updated = WeeklySchedule.get_day_availability(profile.id, 1)
      assert updated.start_time == ~T[08:00:00]
      assert updated.end_time == ~T[18:00:00]
    end

    test "returns error for invalid time format", %{profile: profile} do
      result = AvailabilityActions.update_day_hours(profile.id, 1, "invalid", "18:00")

      assert {:error, :invalid_time_format} = result
    end

    test "accepts early morning start times", %{profile: profile} do
      assert {:ok, _result} = AvailabilityActions.update_day_hours(profile.id, 1, "06:00", "14:00")

      updated = WeeklySchedule.get_day_availability(profile.id, 1)
      assert updated.start_time == ~T[06:00:00]
    end

    test "accepts late evening end times", %{profile: profile} do
      assert {:ok, _result} = AvailabilityActions.update_day_hours(profile.id, 1, "12:00", "22:00")

      updated = WeeklySchedule.get_day_availability(profile.id, 1)
      assert updated.end_time == ~T[22:00:00]
    end
  end

  # =====================================
  # Break Management Behaviors
  # =====================================

  describe "when adding a break to availability" do
    setup do
      %{profile: profile, day: day} = create_profile_with_day()
      %{profile: profile, day: day}
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

  describe "when adding a quick break" do
    setup do
      %{profile: profile, day: day} = create_profile_with_day()
      %{profile: profile, day: day}
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
  end

  describe "when deleting a break" do
    setup do
      %{profile: profile, day: day} = create_profile_with_day()

      {:ok, break} = Breaks.add_break(day.id, ~T[12:00:00], ~T[13:00:00], "Lunch")

      %{profile: profile, day: day, break: break}
    end

    test "successfully deletes existing break", %{day: day, break: break} do
      assert {:ok, _deleted} = AvailabilityActions.delete_break(break.id)

      breaks = Breaks.get_breaks_for_day(day.id)
      assert breaks == []
    end

    test "returns error for non-existent break" do
      result = AvailabilityActions.delete_break(999_999)

      assert {:error, "Break not found"} = result
    end
  end

  # =====================================
  # Bulk Operations Behaviors
  # =====================================

  describe "when copying day settings" do
    setup do
      %{profile: profile} = create_profile()

      # Create Monday with specific settings
      {:ok, monday} =
        WeeklySchedule.create_day_availability(profile.id, 1, %{
          is_available: true,
          start_time: ~T[08:00:00],
          end_time: ~T[16:00:00]
        })

      %{profile: profile, monday: monday}
    end

    test "copies settings from one day to multiple days", %{profile: profile} do
      # Copy Monday settings to Tuesday, Wednesday
      assert {:ok, _result} = AvailabilityActions.copy_day_settings(profile.id, 1, [2, 3])

      tuesday = WeeklySchedule.get_day_availability(profile.id, 2)
      wednesday = WeeklySchedule.get_day_availability(profile.id, 3)

      assert tuesday.is_available == true
      assert tuesday.start_time == ~T[08:00:00]
      assert tuesday.end_time == ~T[16:00:00]

      assert wednesday.is_available == true
      assert wednesday.start_time == ~T[08:00:00]
    end

    test "returns error when source day not found", %{profile: profile} do
      # Sunday (7) doesn't exist yet
      result = AvailabilityActions.copy_day_settings(profile.id, 7, [2, 3])

      assert {:error, "Source day not found"} = result
    end
  end

  describe "when applying preset schedules" do
    setup do
      %{profile: profile} = create_profile()
      %{profile: profile}
    end

    test "applies 9-5 workday preset", %{profile: profile} do
      assert {:ok, _result} = AvailabilityActions.apply_preset(profile.id, "9-5", [1, 2, 3])

      monday = WeeklySchedule.get_day_availability(profile.id, 1)
      assert monday.is_available == true
      assert monday.start_time == ~T[09:00:00]
      assert monday.end_time == ~T[17:00:00]
    end

    test "applies 8-6 preset", %{profile: profile} do
      assert {:ok, _result} = AvailabilityActions.apply_preset(profile.id, "8-6", [1])

      monday = WeeklySchedule.get_day_availability(profile.id, 1)
      assert monday.start_time == ~T[08:00:00]
      assert monday.end_time == ~T[18:00:00]
    end

    test "applies 10-6 preset", %{profile: profile} do
      assert {:ok, _result} = AvailabilityActions.apply_preset(profile.id, "10-6", [1])

      monday = WeeklySchedule.get_day_availability(profile.id, 1)
      assert monday.start_time == ~T[10:00:00]
      assert monday.end_time == ~T[18:00:00]
    end

    test "applies unavailable preset", %{profile: profile} do
      assert {:ok, _result} = AvailabilityActions.apply_preset(profile.id, "unavailable", [1])

      monday = WeeklySchedule.get_day_availability(profile.id, 1)
      assert monday.is_available == false
    end

    test "returns error for unknown preset", %{profile: profile} do
      result = AvailabilityActions.apply_preset(profile.id, "nonexistent", [1])

      assert {:error, message} = result
      assert message =~ "Unknown preset"
    end
  end

  describe "when clearing day settings" do
    setup do
      %{profile: profile, day: day} = create_profile_with_day()

      # Add some breaks
      {:ok, _break} = Breaks.add_break(day.id, ~T[12:00:00], ~T[13:00:00], "Lunch")

      %{profile: profile, day: day}
    end

    test "sets day to unavailable and clears breaks", %{profile: profile, day: day} do
      assert {:ok, _result} = AvailabilityActions.clear_day_settings(profile.id, 1)

      updated = WeeklySchedule.get_day_availability(profile.id, 1)
      assert updated.is_available == false

      breaks = Breaks.get_breaks_for_day(day.id)
      assert breaks == []
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
