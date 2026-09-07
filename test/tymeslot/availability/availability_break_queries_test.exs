defmodule Tymeslot.Availability.AvailabilityBreakQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Availability.AvailabilityBreakQueries
  alias Tymeslot.Availability.AvailabilityBreakSchema

  describe "create_break/1" do
    test "creates a break with valid attributes" do
      weekly_availability = insert(:weekly_availability)

      attrs = %{
        weekly_availability_id: weekly_availability.id,
        start_time: ~T[12:00:00],
        end_time: ~T[13:00:00],
        label: "Lunch Break"
      }

      assert {:ok, break} = AvailabilityBreakQueries.create_break(attrs)
      assert break.weekly_availability_id == weekly_availability.id
      assert break.start_time == ~T[12:00:00]
      assert break.end_time == ~T[13:00:00]
      assert break.label == "Lunch Break"
    end

    test "fails to create break with invalid time ordering" do
      weekly_availability = insert(:weekly_availability)

      attrs = %{
        weekly_availability_id: weekly_availability.id,
        start_time: ~T[13:00:00],
        end_time: ~T[12:00:00]
      }

      assert {:error, changeset} = AvailabilityBreakQueries.create_break(attrs)
      assert "must be after start time" in errors_on(changeset).end_time
    end

    test "assigns default sort_order of 0 when not provided" do
      weekly_availability = insert(:weekly_availability)

      attrs = %{
        weekly_availability_id: weekly_availability.id,
        start_time: ~T[12:00:00],
        end_time: ~T[13:00:00]
      }

      assert {:ok, break} = AvailabilityBreakQueries.create_break(attrs)
      assert break.sort_order == 0
    end
  end

  describe "get_break/1" do
    test "retrieves an existing break" do
      break = insert(:availability_break)

      result = AvailabilityBreakQueries.get_break(break.id)
      assert result.id == break.id
    end

    test "returns nil when break does not exist" do
      result = AvailabilityBreakQueries.get_break(999_999)
      assert result == nil
    end
  end

  describe "get_breaks_by_weekly_availability/1" do
    test "retrieves all breaks for a weekly availability" do
      weekly_availability = insert(:weekly_availability)

      break1 =
        insert(:availability_break, weekly_availability: weekly_availability, sort_order: 1)

      break2 =
        insert(:availability_break, weekly_availability: weekly_availability, sort_order: 0)

      _other_break = insert(:availability_break)

      result = AvailabilityBreakQueries.get_breaks_by_weekly_availability(weekly_availability.id)

      assert length(result) == 2
      assert Enum.map(result, & &1.id) == [break2.id, break1.id]
    end

    test "returns breaks in sort_order ascending order" do
      weekly_availability = insert(:weekly_availability)

      break1 =
        insert(:availability_break, weekly_availability: weekly_availability, sort_order: 2)

      break2 =
        insert(:availability_break, weekly_availability: weekly_availability, sort_order: 0)

      break3 =
        insert(:availability_break, weekly_availability: weekly_availability, sort_order: 1)

      result = AvailabilityBreakQueries.get_breaks_by_weekly_availability(weekly_availability.id)

      assert Enum.map(result, & &1.sort_order) == [0, 1, 2]
      assert Enum.map(result, & &1.id) == [break2.id, break3.id, break1.id]
    end

    test "returns empty list when no breaks exist" do
      weekly_availability = insert(:weekly_availability)

      result = AvailabilityBreakQueries.get_breaks_by_weekly_availability(weekly_availability.id)

      assert result == []
    end
  end

  describe "delete_break/1" do
    test "deletes an existing break" do
      break = insert(:availability_break)

      assert {:ok, deleted} = AvailabilityBreakQueries.delete_break(break)
      assert deleted.id == break.id
      assert AvailabilityBreakQueries.get_break(break.id) == nil
    end
  end

  describe "get_next_sort_order/1" do
    test "returns 0 when no breaks exist" do
      weekly_availability = insert(:weekly_availability)

      result = AvailabilityBreakQueries.get_next_sort_order(weekly_availability.id)

      assert result == 0
    end

    test "returns max sort_order + 1 when breaks exist" do
      weekly_availability = insert(:weekly_availability)
      insert(:availability_break, weekly_availability: weekly_availability, sort_order: 2)
      insert(:availability_break, weekly_availability: weekly_availability, sort_order: 5)
      insert(:availability_break, weekly_availability: weekly_availability, sort_order: 1)

      result = AvailabilityBreakQueries.get_next_sort_order(weekly_availability.id)

      assert result == 6
    end
  end

  describe "get_work_hours/1" do
    test "retrieves work hours for a weekly availability" do
      weekly_availability =
        insert(:weekly_availability, start_time: ~T[09:00:00], end_time: ~T[17:00:00])

      result = AvailabilityBreakQueries.get_work_hours(weekly_availability.id)

      assert result == {~T[09:00:00], ~T[17:00:00]}
    end

    test "returns nil when weekly availability does not exist" do
      result = AvailabilityBreakQueries.get_work_hours(999_999)

      assert result == nil
    end
  end

  describe "get_existing_breaks_for_validation/2" do
    test "retrieves all breaks for validation" do
      weekly_availability = insert(:weekly_availability)
      break1 = insert(:availability_break, weekly_availability: weekly_availability)
      break2 = insert(:availability_break, weekly_availability: weekly_availability)

      result =
        AvailabilityBreakQueries.get_existing_breaks_for_validation(weekly_availability.id)

      assert length(result) == 2

      assert Enum.any?(result, fn {id, _start_time, _end_time} -> id == break1.id end)
      assert Enum.any?(result, fn {id, _start_time, _end_time} -> id == break2.id end)
    end

    test "excludes specified break from results" do
      weekly_availability = insert(:weekly_availability)
      break1 = insert(:availability_break, weekly_availability: weekly_availability)
      break2 = insert(:availability_break, weekly_availability: weekly_availability)

      result =
        AvailabilityBreakQueries.get_existing_breaks_for_validation(
          weekly_availability.id,
          break1.id
        )

      assert length(result) == 1
      assert [{id, _start_time, _end_time}] = result
      assert id == break2.id
    end

    test "returns break data as tuples with id, start_time, end_time" do
      weekly_availability = insert(:weekly_availability)

      break =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[12:00:00],
          end_time: ~T[13:00:00]
        )

      result =
        AvailabilityBreakQueries.get_existing_breaks_for_validation(weekly_availability.id)

      assert [{id, start_time, end_time}] = result
      assert id == break.id
      assert start_time == ~T[12:00:00]
      assert end_time == ~T[13:00:00]
    end
  end

  describe "reorder_breaks/2" do
    test "updates sort order for breaks" do
      weekly_availability = insert(:weekly_availability)

      break1 =
        insert(:availability_break, weekly_availability: weekly_availability, sort_order: 0)

      break2 =
        insert(:availability_break, weekly_availability: weekly_availability, sort_order: 1)

      break3 =
        insert(:availability_break, weekly_availability: weekly_availability, sort_order: 2)

      # Reorder: break3, break1, break2
      new_order = [break3.id, break1.id, break2.id]

      assert {:ok, _result} =
               AvailabilityBreakQueries.reorder_breaks(weekly_availability.id, new_order)

      # Verify new order
      updated_break1 = AvailabilityBreakQueries.get_break(break1.id)
      updated_break2 = AvailabilityBreakQueries.get_break(break2.id)
      updated_break3 = AvailabilityBreakQueries.get_break(break3.id)

      assert updated_break3.sort_order == 0
      assert updated_break1.sort_order == 1
      assert updated_break2.sort_order == 2
    end

    test "only updates breaks belonging to the specified weekly availability" do
      weekly_availability1 = insert(:weekly_availability)
      weekly_availability2 = insert(:weekly_availability)

      break1 =
        insert(:availability_break, weekly_availability: weekly_availability1, sort_order: 0)

      break2 =
        insert(:availability_break, weekly_availability: weekly_availability2, sort_order: 0)

      # Try to reorder break2 (different weekly availability)
      new_order = [break2.id, break1.id]

      AvailabilityBreakQueries.reorder_breaks(weekly_availability1.id, new_order)

      # break2 should not be updated (belongs to different weekly availability)
      updated_break2 = AvailabilityBreakQueries.get_break(break2.id)
      assert updated_break2.sort_order == 0
    end
  end

  describe "insert_changeset/1 and update_changeset/1" do
    test "insert_changeset inserts a pre-validated changeset" do
      weekly_availability = insert(:weekly_availability)

      changeset =
        AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, %{
          weekly_availability_id: weekly_availability.id,
          start_time: ~T[12:00:00],
          end_time: ~T[13:00:00]
        })

      assert {:ok, break} = AvailabilityBreakQueries.insert_changeset(changeset)
      assert break.weekly_availability_id == weekly_availability.id
    end

    test "update_changeset updates a pre-validated changeset" do
      break = insert(:availability_break, label: "Old Label")

      changeset = AvailabilityBreakSchema.changeset(break, %{label: "New Label"})

      assert {:ok, updated} = AvailabilityBreakQueries.update_changeset(changeset)
      assert updated.label == "New Label"
    end
  end
end
