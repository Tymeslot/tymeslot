defmodule Tymeslot.MeetingTypes.MeetingTypeQueriesReorderTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  describe "reorder_meeting_types/2" do
    test "reorders meeting types and updates sort_order" do
      user = insert(:user)

      # Create meeting types with initial sort orders
      mt1 = insert(:meeting_type, user: user, name: "Alpha", sort_order: 0)
      mt2 = insert(:meeting_type, user: user, name: "Beta", sort_order: 1)
      mt3 = insert(:meeting_type, user: user, name: "Gamma", sort_order: 2)

      # Reorder: move Gamma to first, Alpha to second, Beta to third
      new_order = [mt3.id, mt1.id, mt2.id]

      assert {:ok, _result} = MeetingTypeQueries.reorder_meeting_types(user.id, new_order)

      # Verify new sort order
      types = MeetingTypeQueries.list_all_meeting_types(user.id)

      assert Enum.at(types, 0).id == mt3.id
      assert Enum.at(types, 0).sort_order == 0

      assert Enum.at(types, 1).id == mt1.id
      assert Enum.at(types, 1).sort_order == 1

      assert Enum.at(types, 2).id == mt2.id
      assert Enum.at(types, 2).sort_order == 2
    end

    test "prevents reordering another user's meeting types" do
      user1 = insert(:user)
      user2 = insert(:user)

      # Create meeting types for user1
      mt1 = insert(:meeting_type, user: user1, name: "User1 Type1", sort_order: 0)
      mt2 = insert(:meeting_type, user: user1, name: "User1 Type2", sort_order: 1)

      # Try to reorder user1's types using user2's id — rolls back because
      # none of user2's types match the given IDs
      new_order = [mt2.id, mt1.id]

      assert {:error, :partial_reorder} =
               MeetingTypeQueries.reorder_meeting_types(user2.id, new_order)

      # Verify user1's types were NOT reordered (security check)
      types = MeetingTypeQueries.list_all_meeting_types(user1.id)
      assert Enum.at(types, 0).id == mt1.id
      assert Enum.at(types, 0).sort_order == 0
      assert Enum.at(types, 1).id == mt2.id
      assert Enum.at(types, 1).sort_order == 1
    end

    test "an empty list is a no-op that leaves the user's existing order untouched" do
      user = insert(:user)
      mt1 = insert(:meeting_type, user: user, name: "Alpha", sort_order: 0)
      mt2 = insert(:meeting_type, user: user, name: "Beta", sort_order: 1)

      assert {:ok, []} = MeetingTypeQueries.reorder_meeting_types(user.id, [])

      types = MeetingTypeQueries.list_all_meeting_types(user.id)
      assert Enum.map(types, & &1.id) == [mt1.id, mt2.id]
      assert Enum.map(types, & &1.sort_order) == [0, 1]
    end

    test "normalizes sort order from zero" do
      user = insert(:user)

      # Create meeting types with gaps in sort order
      mt1 = insert(:meeting_type, user: user, name: "First", sort_order: 5)
      mt2 = insert(:meeting_type, user: user, name: "Second", sort_order: 10)
      mt3 = insert(:meeting_type, user: user, name: "Third", sort_order: 20)

      # Reorder them
      new_order = [mt1.id, mt2.id, mt3.id]
      assert {:ok, _result} = MeetingTypeQueries.reorder_meeting_types(user.id, new_order)

      # Verify sort order is normalized to 0, 1, 2
      types = MeetingTypeQueries.list_all_meeting_types(user.id)
      assert Enum.at(types, 0).sort_order == 0
      assert Enum.at(types, 1).sort_order == 1
      assert Enum.at(types, 2).sort_order == 2
    end

    test "persists reordering across queries" do
      user = insert(:user)

      mt1 = insert(:meeting_type, user: user, name: "A", sort_order: 0)
      mt2 = insert(:meeting_type, user: user, name: "B", sort_order: 1)
      mt3 = insert(:meeting_type, user: user, name: "C", sort_order: 2)

      # Reverse order
      new_order = [mt3.id, mt2.id, mt1.id]

      # Use a slightly older timestamp for initial records to ensure updated_at is greater
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-10, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(MeetingTypeSchema, set: [updated_at: past_time])

      # Refresh mt3 to get the past_time
      mt3 = Repo.get!(MeetingTypeSchema, mt3.id)

      assert {:ok, _result} = MeetingTypeQueries.reorder_meeting_types(user.id, new_order)

      # Query again to verify persistence and updated_at
      types = MeetingTypeQueries.list_all_meeting_types(user.id)
      assert length(types) == 3
      assert Enum.at(types, 0).id == mt3.id
      assert Enum.at(types, 1).id == mt2.id
      assert Enum.at(types, 2).id == mt1.id

      # Verify updated_at was updated (should be after past_time)
      assert DateTime.compare(Enum.at(types, 0).updated_at, mt3.updated_at) == :gt
    end

    test "rolls back when list contains nonexistent IDs" do
      user = insert(:user)

      mt1 = insert(:meeting_type, user: user, name: "Existing", sort_order: 0)

      # Include one valid and one nonexistent ID
      assert {:error, :partial_reorder} =
               MeetingTypeQueries.reorder_meeting_types(user.id, [mt1.id, 999_999])

      # Verify original sort order is preserved (transaction rolled back)
      reloaded = Repo.get!(MeetingTypeSchema, mt1.id)
      assert reloaded.sort_order == 0
    end
  end
end
