defmodule Tymeslot.MeetingTypes.MeetingTypeQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  describe "list_active_meeting_types/1" do
    test "returns active meeting types for user ordered by sort_order and name" do
      user = insert(:user)

      # Create meeting types with different sort orders
      mt1 = insert(:meeting_type, user: user, name: "Z Meeting", sort_order: 1, is_active: true)
      mt2 = insert(:meeting_type, user: user, name: "A Meeting", sort_order: 0, is_active: true)
      mt3 = insert(:meeting_type, user: user, name: "B Meeting", sort_order: 0, is_active: true)

      # Create inactive meeting type (should not appear)
      insert(:meeting_type, user: user, name: "Inactive", is_active: false)

      # Create meeting type for different user (should not appear)
      other_user = insert(:user)
      insert(:meeting_type, user: other_user, name: "Other User", is_active: true)

      result = MeetingTypeQueries.list_active_meeting_types(user.id)

      assert length(result) == 3
      # sort_order 0, name "A Meeting"
      assert Enum.at(result, 0).id == mt2.id
      # sort_order 0, name "B Meeting"
      assert Enum.at(result, 1).id == mt3.id
      # sort_order 1, name "Z Meeting"
      assert Enum.at(result, 2).id == mt1.id
    end

    test "returns empty list when user has no active meeting types" do
      user = insert(:user)

      # Create inactive meeting type
      insert(:meeting_type, user: user, is_active: false)

      result = MeetingTypeQueries.list_active_meeting_types(user.id)
      assert result == []
    end

    test "returns empty list when user has no meeting types" do
      user = insert(:user)

      result = MeetingTypeQueries.list_active_meeting_types(user.id)
      assert result == []
    end
  end

  describe "list_all_meeting_types/1" do
    test "returns all meeting types for user ordered by sort_order and name" do
      user = insert(:user)

      # Create meeting types with different sort orders and active states
      mt1 = insert(:meeting_type, user: user, name: "Z Meeting", sort_order: 1, is_active: true)
      mt2 = insert(:meeting_type, user: user, name: "A Meeting", sort_order: 0, is_active: true)
      mt3 = insert(:meeting_type, user: user, name: "B Meeting", sort_order: 0, is_active: false)

      # Create meeting type for different user (should not appear)
      other_user = insert(:user)
      insert(:meeting_type, user: other_user, name: "Other User", is_active: true)

      result = MeetingTypeQueries.list_all_meeting_types(user.id)

      assert length(result) == 3
      # sort_order 0, name "A Meeting"
      assert Enum.at(result, 0).id == mt2.id
      # sort_order 0, name "B Meeting"
      assert Enum.at(result, 1).id == mt3.id
      # sort_order 1, name "Z Meeting"
      assert Enum.at(result, 2).id == mt1.id
    end

    test "returns empty list when user has no meeting types" do
      user = insert(:user)

      result = MeetingTypeQueries.list_all_meeting_types(user.id)
      assert result == []
    end
  end

  describe "get_meeting_type/2" do
    test "returns meeting type when it exists for user" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Test Meeting")

      result = MeetingTypeQueries.get_meeting_type(meeting_type.id, user.id)
      assert result.id == meeting_type.id
      assert result.name == "Test Meeting"
    end

    test "returns nil when meeting type exists but belongs to different user" do
      user1 = insert(:user)
      user2 = insert(:user)
      meeting_type = insert(:meeting_type, user: user1)

      result = MeetingTypeQueries.get_meeting_type(meeting_type.id, user2.id)
      assert result == nil
    end
  end

  describe "create_meeting_type/1" do
    test "creates meeting type with valid attributes" do
      user = insert(:user)

      attrs = %{
        name: "New Meeting Type",
        description: "A new meeting type for testing",
        duration_minutes: 45,
        icon: "hero-flag",
        is_active: true,
        allow_video: false,
        sort_order: 3,
        user_id: user.id
      }

      assert {:ok, meeting_type} = MeetingTypeQueries.create_meeting_type(attrs)
      assert meeting_type.name == "New Meeting Type"
      assert meeting_type.description == "A new meeting type for testing"
      assert meeting_type.duration_minutes == 45
      assert meeting_type.icon == "hero-flag"
      assert meeting_type.is_active == true
      assert meeting_type.allow_video == false
      assert meeting_type.sort_order == 3
      assert meeting_type.user_id == user.id
    end

    test "creates meeting type with minimal attributes" do
      user = insert(:user)

      attrs = %{
        name: "Minimal Meeting",
        duration_minutes: 30,
        user_id: user.id
      }

      assert {:ok, meeting_type} = MeetingTypeQueries.create_meeting_type(attrs)
      assert meeting_type.name == "Minimal Meeting"
      assert meeting_type.duration_minutes == 30
      assert meeting_type.user_id == user.id
      # Check default values
      assert meeting_type.is_active == true
      assert meeting_type.allow_video == false
      assert meeting_type.sort_order == 0
    end

    test "returns error with invalid attributes" do
      assert {:error, changeset} = MeetingTypeQueries.create_meeting_type(%{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).duration_minutes
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "returns error with duplicate name for same user" do
      user = insert(:user)

      # Create first meeting type
      attrs1 = %{
        name: "Duplicate Name",
        duration_minutes: 30,
        user_id: user.id
      }

      assert {:ok, _meeting_type1} = MeetingTypeQueries.create_meeting_type(attrs1)

      # Attempt to create second meeting type with same name
      attrs2 = %{
        name: "Duplicate Name",
        duration_minutes: 60,
        user_id: user.id
      }

      assert {:error, changeset} = MeetingTypeQueries.create_meeting_type(attrs2)
      assert "You already have a meeting type with this name" in errors_on(changeset).user_id
    end

    test "allows same name for different users" do
      user1 = insert(:user)
      user2 = insert(:user)
      name = "Same Name"

      # Create meeting type for user1
      attrs1 = %{
        name: name,
        duration_minutes: 30,
        user_id: user1.id
      }

      assert {:ok, _meeting_type1} = MeetingTypeQueries.create_meeting_type(attrs1)

      # Create meeting type with same name for user2 (should succeed)
      attrs2 = %{
        name: name,
        duration_minutes: 60,
        user_id: user2.id
      }

      assert {:ok, _meeting_type2} = MeetingTypeQueries.create_meeting_type(attrs2)
    end
  end

  describe "update_meeting_type/2" do
    test "updates meeting type with valid attributes" do
      user = insert(:user)

      meeting_type =
        insert(:meeting_type, user: user, name: "Original Name", duration_minutes: 30)

      attrs = %{
        name: "Updated Name",
        duration_minutes: 45,
        description: "Updated description"
      }

      assert {:ok, updated} = MeetingTypeQueries.update_meeting_type(meeting_type, attrs)
      assert updated.name == "Updated Name"
      assert updated.duration_minutes == 45
      assert updated.description == "Updated description"
      assert updated.id == meeting_type.id
    end

    test "returns error with invalid attributes" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      attrs = %{
        # Invalid: empty name
        name: "",
        # Invalid: duration must be > 0
        duration_minutes: 0
      }

      assert {:error, changeset} = MeetingTypeQueries.update_meeting_type(meeting_type, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
      assert "must be greater than or equal to 1" in errors_on(changeset).duration_minutes
    end

    test "returns error when updating to duplicate name" do
      user = insert(:user)
      _meeting_type1 = insert(:meeting_type, user: user, name: "First Meeting")
      meeting_type2 = insert(:meeting_type, user: user, name: "Second Meeting")

      # Try to update meeting_type2 to have the same name as meeting_type1
      attrs = %{name: "First Meeting"}

      assert {:error, changeset} = MeetingTypeQueries.update_meeting_type(meeting_type2, attrs)
      assert "You already have a meeting type with this name" in errors_on(changeset).user_id
    end

    test "allows updating to same name (no-op)" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Same Name")

      attrs = %{name: "Same Name", duration_minutes: 45}

      assert {:ok, updated} = MeetingTypeQueries.update_meeting_type(meeting_type, attrs)
      assert updated.name == "Same Name"
      assert updated.duration_minutes == 45
    end
  end

  describe "delete_meeting_type/1" do
    test "deletes meeting type successfully" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      assert {:ok, deleted} = MeetingTypeQueries.delete_meeting_type(meeting_type)
      assert deleted.id == meeting_type.id

      # Verify it's deleted
      assert nil == MeetingTypeQueries.get_meeting_type(meeting_type.id, user.id)
    end

    test "returns error when deleting non-existent meeting type" do
      # This would typically be handled by trying to delete a struct that doesn't exist
      # The actual behavior depends on how the calling code handles it
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      # Delete it first
      assert {:ok, _result} = MeetingTypeQueries.delete_meeting_type(meeting_type)

      # Try to delete again - this should raise an error or return a specific response
      assert_raise Ecto.StaleEntryError, fn ->
        MeetingTypeQueries.delete_meeting_type(meeting_type)
      end
    end
  end

  describe "bulk_insert_meeting_types/1" do
    test "inserts multiple meeting types at once" do
      user = insert(:user)
      now = DateTime.utc_now(:second)

      attrs_list = [
        %{
          user_id: user.id,
          name: "15 Minutes",
          description: "Quick chat",
          duration_minutes: 15,
          icon: "hero-bolt",
          sort_order: 0,
          is_active: true,
          allow_video: false,
          calendar_integration_id: nil,
          target_calendar_id: nil,
          reminder_config: [%{value: 30, unit: "minutes"}],
          inserted_at: now,
          updated_at: now
        },
        %{
          user_id: user.id,
          name: "30 Minutes",
          description: "In-depth discussion",
          duration_minutes: 30,
          icon: "hero-rocket-launch",
          sort_order: 1,
          is_active: true,
          allow_video: false,
          calendar_integration_id: nil,
          target_calendar_id: nil,
          reminder_config: [%{value: 30, unit: "minutes"}],
          inserted_at: now,
          updated_at: now
        }
      ]

      assert {:ok, meeting_types} = MeetingTypeQueries.bulk_insert_meeting_types(attrs_list)
      assert length(meeting_types) == 2

      names = Enum.map(meeting_types, & &1.name)
      assert "15 Minutes" in names
      assert "30 Minutes" in names
    end

    test "returns ok with empty list for empty input" do
      assert {:ok, []} = MeetingTypeQueries.bulk_insert_meeting_types([])
    end
  end

  describe "existing_names/1" do
    test "returns names of existing meeting types as MapSet" do
      user = insert(:user)
      insert(:meeting_type, user: user, name: "Alpha")
      insert(:meeting_type, user: user, name: "Beta")

      names = MeetingTypeQueries.existing_names(user.id)
      assert MapSet.member?(names, "Alpha")
      assert MapSet.member?(names, "Beta")
      refute MapSet.member?(names, "Gamma")
    end

    test "returns empty MapSet when user has no meeting types" do
      user = insert(:user)
      assert MeetingTypeQueries.existing_names(user.id) == MapSet.new()
    end
  end

  describe "has_meeting_types?/1" do
    test "returns true when user has meeting types" do
      user = insert(:user)
      insert(:meeting_type, user: user)

      assert MeetingTypeQueries.has_meeting_types?(user.id) == true
    end

    test "returns true when user has inactive meeting types" do
      user = insert(:user)
      insert(:meeting_type, user: user, is_active: false)

      assert MeetingTypeQueries.has_meeting_types?(user.id) == true
    end

    test "returns false when user has no meeting types" do
      user = insert(:user)

      assert MeetingTypeQueries.has_meeting_types?(user.id) == false
    end

    test "returns false for non-existent user" do
      assert MeetingTypeQueries.has_meeting_types?(999_999) == false
    end

    test "returns false after deleting all meeting types" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      # Verify user has meeting types
      assert MeetingTypeQueries.has_meeting_types?(user.id) == true

      # Delete the meeting type
      MeetingTypeQueries.delete_meeting_type(meeting_type)

      # Verify user no longer has meeting types
      assert MeetingTypeQueries.has_meeting_types?(user.id) == false
    end
  end

  describe "create_default_meeting_types_individual/1 (legacy version)" do
    test "creates default meeting types individually" do
      user = insert(:user)

      {:ok, meeting_types} = MeetingTypeQueries.create_default_meeting_types_individual(user.id)

      assert length(meeting_types) == 2

      # Verify both types were created
      names = Enum.map(meeting_types, & &1.name)
      assert "15 Minutes" in names
      assert "30 Minutes" in names

      # Verify they all belong to the user
      assert Enum.all?(meeting_types, &(&1.user_id == user.id))
    end

    test "handles duplicates gracefully in individual creation" do
      user = insert(:user)

      # Create existing meeting type
      insert(:meeting_type, user: user, name: "15 Minutes")

      {:ok, meeting_types} = MeetingTypeQueries.create_default_meeting_types_individual(user.id)

      # Should only create the non-duplicate type
      assert length(meeting_types) == 1
      assert hd(meeting_types).name == "30 Minutes"
    end

    test "returns error for invalid user_id in individual creation" do
      assert {:error, :invalid_user_id} =
               MeetingTypeQueries.create_default_meeting_types_individual(nil)
    end
  end

  describe "count_for_user/1" do
    test "returns count of meeting types for user" do
      user1 = insert(:user)
      user2 = insert(:user)

      insert(:meeting_type, user: user1)
      insert(:meeting_type, user: user1)
      insert(:meeting_type, user: user2)

      count = MeetingTypeQueries.count_for_user(user1.id)
      assert count == 2
    end

    test "returns zero when user has no meeting types" do
      user = insert(:user)

      count = MeetingTypeQueries.count_for_user(user.id)
      assert count == 0
    end
  end

  describe "get_meeting_type!/1" do
    test "returns meeting type when it exists" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Test Type")

      result = MeetingTypeQueries.get_meeting_type!(meeting_type.id)
      assert result.id == meeting_type.id
      assert result.name == "Test Type"
    end

    test "raises when meeting type doesn't exist" do
      assert_raise Ecto.NoResultsError, fn ->
        MeetingTypeQueries.get_meeting_type!(999_999)
      end
    end
  end

  describe "clear_calendar_references/1" do
    test "clears calendar fields on meeting types referencing the given integration" do
      user = insert(:user)
      calendar = insert(:calendar_integration, user: user)

      mt =
        insert(:meeting_type,
          user: user,
          calendar_integration_id: calendar.id,
          target_calendar_id: "cal-1"
        )

      # Another meeting type with a different integration (should be untouched)
      other_calendar = insert(:calendar_integration, user: user)

      mt_other =
        insert(:meeting_type,
          user: user,
          name: "Other",
          calendar_integration_id: other_calendar.id,
          target_calendar_id: "other-cal"
        )

      {updated_count, _nil} = MeetingTypeQueries.clear_calendar_references(calendar.id)

      assert updated_count == 1

      reloaded = Repo.get!(MeetingTypeSchema, mt.id)
      assert reloaded.calendar_integration_id == nil
      assert reloaded.target_calendar_id == nil

      reloaded_other = Repo.get!(MeetingTypeSchema, mt_other.id)
      assert reloaded_other.calendar_integration_id == other_calendar.id
      assert reloaded_other.target_calendar_id == "other-cal"
    end
  end

  describe "clear_payments_for_user/1" do
    test "resets payment_required and price_cents on the user's meeting types" do
      user = insert(:user)
      paid_mt = insert(:meeting_type, user: user, payment_required: true, price_cents: 5000)
      free_mt = insert(:meeting_type, user: user, payment_required: false, price_cents: nil)

      MeetingTypeQueries.clear_payments_for_user(user.id)

      assert %MeetingTypeSchema{payment_required: false, price_cents: nil} =
               Repo.reload(paid_mt)

      assert %MeetingTypeSchema{payment_required: false, price_cents: nil} =
               Repo.reload(free_mt)
    end

    test "leaves other users' meeting types untouched" do
      user = insert(:user)
      other = insert(:user)
      paid_mt = insert(:meeting_type, user: other, payment_required: true, price_cents: 7500)

      MeetingTypeQueries.clear_payments_for_user(user.id)

      assert %MeetingTypeSchema{payment_required: true, price_cents: 7500} =
               Repo.reload(paid_mt)
    end
  end
end
