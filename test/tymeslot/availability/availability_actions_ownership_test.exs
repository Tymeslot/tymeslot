defmodule Tymeslot.Availability.AvailabilityActionsOwnershipTest do
  use Tymeslot.DataCase, async: true
  @moduletag :availability

  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.WeeklySchedule

  # =====================================
  # Ownership
  # =====================================

  # Ids reach these actions from the editor's own assigns today, but the
  # context is the guard: another profile's schedule or day is not found, and
  # nothing about it changes.
  describe "when the ids belong to another profile" do
    setup do
      %{schedule: mine} = create_profile_with_day()
      %{schedule: theirs, day: their_day} = create_profile_with_day()
      %{mine: mine, theirs: theirs, their_day: their_day}
    end

    test "add_break refuses another profile's day", %{mine: mine, their_day: their_day} do
      assert {:error, :not_found} =
               AvailabilityActions.add_break(mine.profile_id, their_day.id, "12:00", "13:00", "")

      assert breaks_for_day(their_day.id) == []
    end

    test "add_quick_break refuses another profile's day", %{mine: mine, their_day: their_day} do
      assert {:error, :not_found} =
               AvailabilityActions.add_quick_break(mine.profile_id, their_day.id, "12:00", 30)

      assert breaks_for_day(their_day.id) == []
    end

    test "update_day_hours refuses another profile's schedule", %{mine: mine, theirs: theirs} do
      assert {:error, :not_found} =
               AvailabilityActions.update_day_hours(
                 mine.profile_id,
                 theirs.id,
                 1,
                 "06:00",
                 "07:00"
               )

      assert %{start_time: ~T[09:00:00]} = WeeklySchedule.get_day_availability(theirs.id, 1)
    end

    test "toggle_day_availability refuses another profile's schedule", %{
      mine: mine,
      theirs: theirs
    } do
      assert {:error, :not_found} =
               AvailabilityActions.toggle_day_availability(mine.profile_id, theirs.id, 1, true)

      assert %{is_available: true} = WeeklySchedule.get_day_availability(theirs.id, 1)
    end

    test "clear_day_settings refuses another profile's schedule", %{mine: mine, theirs: theirs} do
      assert {:error, :not_found} =
               AvailabilityActions.clear_day_settings(mine.profile_id, theirs.id, 1)

      assert %{is_available: true} = WeeklySchedule.get_day_availability(theirs.id, 1)
    end

    test "copy_day_settings refuses another profile's schedule", %{mine: mine, theirs: theirs} do
      assert {:error, :not_found} =
               AvailabilityActions.copy_day_settings(mine.profile_id, theirs.id, 1, [2])

      assert WeeklySchedule.get_day_availability(theirs.id, 2) == nil
    end

    test "delete_break refuses another profile's schedule", %{
      mine: mine,
      theirs: theirs,
      their_day: their_day
    } do
      {:ok, break} = Breaks.add_break(their_day.id, ~T[12:00:00], ~T[13:00:00], "Lunch")

      assert {:error, :not_found} =
               AvailabilityActions.delete_break(mine.profile_id, break.id, theirs.id)

      assert [_kept] = breaks_for_day(their_day.id)
    end

    test "ensure_complete_schedule creates nothing in another profile's schedule", %{
      mine: mine,
      theirs: theirs
    } do
      assert AvailabilityActions.ensure_complete_schedule(mine.profile_id, [], theirs.id) == []
      assert length(WeeklySchedule.get_weekly_schedule(theirs.id)) == 1
    end
  end

  defp breaks_for_day(day_id),
    do: Repo.all_by(AvailabilityBreakSchema, weekly_availability_id: day_id)
end
