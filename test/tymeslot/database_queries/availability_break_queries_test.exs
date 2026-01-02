defmodule Tymeslot.DatabaseQueries.AvailabilityBreakQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.AvailabilityBreakQueries
  alias Tymeslot.DatabaseSchemas.AvailabilityBreakSchema

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

  describe "get_break/1 and get_break_t/1" do
    test "retrieves an existing break" do
      break = insert(:availability_break)

      result = AvailabilityBreakQueries.get_break(break.id)
      assert result.id == break.id
    end

    test "returns nil when break does not exist" do
      result = AvailabilityBreakQueries.get_break(999_999)
      assert result == nil
    end

    test "get_break_t returns tagged tuple for existing break" do
      break = insert(:availability_break)

      assert {:ok, result} = AvailabilityBreakQueries.get_break_t(break.id)
      assert result.id == break.id
    end

    test "get_break_t returns error tuple when break does not exist" do
      assert {:error, :not_found} = AvailabilityBreakQueries.get_break_t(999_999)
    end
  end

  describe "get_breaks_by_weekly_availability/1" do
    test "retrieves all breaks for a weekly availability" do
      weekly_availability = insert(:weekly_availability)
      break1 = insert(:availability_break, weekly_availability: weekly_availability, sort_order: 1)
      break2 = insert(:availability_break, weekly_availability: weekly_availability, sort_order: 0)
      _other_break = insert(:availability_break)

      result = AvailabilityBreakQueries.get_breaks_by_weekly_availability(weekly_availability.id)

      assert length(result) == 2
      assert Enum.map(result, & &1.id) == [break2.id, break1.id]
    end

    test "returns breaks in sort_order ascending order" do
      weekly_availability = insert(:weekly_availability)
      break1 = insert(:availability_break, weekly_availability: weekly_availability, sort_order: 2)
      break2 = insert(:availability_break, weekly_availability: weekly_availability, sort_order: 0)
      break3 = insert(:availability_break, weekly_availability: weekly_availability, sort_order: 1)

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

  describe "update_break/2" do
    test "updates break attributes" do
      break = insert(:availability_break, label: "Old Label")

      attrs = %{label: "New Label"}

      assert {:ok, updated} = AvailabilityBreakQueries.update_break(break, attrs)
      assert updated.label == "New Label"
      assert updated.id == break.id
    end

    test "updates break times" do
      break = insert(:availability_break, start_time: ~T[10:00:00], end_time: ~T[11:00:00])

      attrs = %{start_time: ~T[14:00:00], end_time: ~T[15:00:00]}

      assert {:ok, updated} = AvailabilityBreakQueries.update_break(break, attrs)
      assert updated.start_time == ~T[14:00:00]
      assert updated.end_time == ~T[15:00:00]
    end

    test "fails with invalid time ordering" do
      break = insert(:availability_break)

      attrs = %{start_time: ~T[15:00:00], end_time: ~T[14:00:00]}

      assert {:error, changeset} = AvailabilityBreakQueries.update_break(break, attrs)
      assert "must be after start time" in errors_on(changeset).end_time
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

  describe "delete_breaks_by_weekly_availability/1" do
    test "deletes all breaks for a weekly availability" do
      weekly_availability = insert(:weekly_availability)
      break1 = insert(:availability_break, weekly_availability: weekly_availability)
      break2 = insert(:availability_break, weekly_availability: weekly_availability)
      other_break = insert(:availability_break)

      {count, _} =
        AvailabilityBreakQueries.delete_breaks_by_weekly_availability(weekly_availability.id)

      assert count == 2
      assert AvailabilityBreakQueries.get_break(break1.id) == nil
      assert AvailabilityBreakQueries.get_break(break2.id) == nil
      assert AvailabilityBreakQueries.get_break(other_break.id) != nil
    end

    test "returns zero count when no breaks exist" do
      weekly_availability = insert(:weekly_availability)

      {count, _} =
        AvailabilityBreakQueries.delete_breaks_by_weekly_availability(weekly_availability.id)

      assert count == 0
    end
  end

  describe "get_breaks_in_time_range/3" do
    test "finds breaks that overlap with the given time range" do
      weekly_availability = insert(:weekly_availability)

      # Overlapping breaks
      break1 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[09:00:00],
          end_time: ~T[10:00:00]
        )

      break2 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[12:00:00],
          end_time: ~T[13:00:00]
        )

      # Non-overlapping break
      _break3 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[15:00:00],
          end_time: ~T[16:00:00]
        )

      # Query for range 08:00 - 14:00
      result =
        AvailabilityBreakQueries.get_breaks_in_time_range(
          weekly_availability.id,
          ~T[08:00:00],
          ~T[14:00:00]
        )

      assert length(result) == 2
      assert Enum.map(result, & &1.id) == [break1.id, break2.id]
    end

    test "finds breaks that partially overlap" do
      weekly_availability = insert(:weekly_availability)

      # Break that starts before range but ends during range
      break1 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[08:00:00],
          end_time: ~T[10:00:00]
        )

      # Break that starts during range but ends after range
      break2 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[11:00:00],
          end_time: ~T[14:00:00]
        )

      # Query for range 09:00 - 12:00
      result =
        AvailabilityBreakQueries.get_breaks_in_time_range(
          weekly_availability.id,
          ~T[09:00:00],
          ~T[12:00:00]
        )

      assert length(result) == 2
      assert Enum.sort(Enum.map(result, & &1.id)) == Enum.sort([break1.id, break2.id])
    end

    test "excludes breaks outside the time range" do
      weekly_availability = insert(:weekly_availability)

      # Break completely before range
      _break1 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[08:00:00],
          end_time: ~T[09:00:00]
        )

      # Break completely after range
      _break2 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[15:00:00],
          end_time: ~T[16:00:00]
        )

      # Query for range 10:00 - 14:00
      result =
        AvailabilityBreakQueries.get_breaks_in_time_range(
          weekly_availability.id,
          ~T[10:00:00],
          ~T[14:00:00]
        )

      assert result == []
    end

    test "returns breaks in chronological order by start_time" do
      weekly_availability = insert(:weekly_availability)

      break1 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[12:00:00],
          end_time: ~T[13:00:00]
        )

      break2 =
        insert(:availability_break,
          weekly_availability: weekly_availability,
          start_time: ~T[09:00:00],
          end_time: ~T[10:00:00]
        )

      result =
        AvailabilityBreakQueries.get_breaks_in_time_range(
          weekly_availability.id,
          ~T[08:00:00],
          ~T[14:00:00]
        )

      assert Enum.map(result, & &1.id) == [break2.id, break1.id]
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

      assert Enum.any?(result, fn {id, _, _} -> id == break1.id end)
      assert Enum.any?(result, fn {id, _, _} -> id == break2.id end)
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
      assert [{id, _, _}] = result
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
      break1 = insert(:availability_break, weekly_availability: weekly_availability, sort_order: 0)
      break2 = insert(:availability_break, weekly_availability: weekly_availability, sort_order: 1)
      break3 = insert(:availability_break, weekly_availability: weekly_availability, sort_order: 2)

      # Reorder: break3, break1, break2
      new_order = [break3.id, break1.id, break2.id]

      assert {:ok, _} =
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
