defmodule Tymeslot.Database.ProfileQueriesUsernameTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.ProfileQueries
  import Tymeslot.Factory

  describe "username operations" do
    test "get_by_username/1 returns profile with matching username" do
      user = insert(:user)
      {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)
      {:ok, updated} = ProfileQueries.update_username(profile, "testuser")

      {:ok, found} = ProfileQueries.get_by_username("testuser")
      assert found.id == updated.id
      assert found.username == "testuser"
    end

    test "get_by_username/1 returns nil for non-existent username" do
      assert {:error, :not_found} == ProfileQueries.get_by_username("nonexistent")
    end

    test "username_available?/1 returns true for available username" do
      assert ProfileQueries.username_available?("available")
    end

    test "username_available?/1 returns false for taken username" do
      user = insert(:user)
      {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)
      {:ok, _} = ProfileQueries.update_username(profile, "taken")

      refute ProfileQueries.username_available?("taken")
    end

    test "update_username/2 updates the username" do
      user = insert(:user)
      {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)

      assert is_nil(profile.username)

      {:ok, updated} = ProfileQueries.update_username(profile, "newusername")
      assert updated.username == "newusername"

      # Verify it's persisted
      {:ok, found} = ProfileQueries.get_by_user_id(user.id)
      assert found.username == "newusername"
    end

    test "update_username/2 enforces uniqueness at database level" do
      user1 = insert(:user)
      user2 = insert(:user)

      {:ok, profile1} = ProfileQueries.get_or_create_by_user_id(user1.id)
      {:ok, profile2} = ProfileQueries.get_or_create_by_user_id(user2.id)

      {:ok, _} = ProfileQueries.update_username(profile1, "duplicate")

      # This should fail due to unique constraint
      assert {:error, changeset} = ProfileQueries.update_username(profile2, "duplicate")
      assert Keyword.has_key?(changeset.errors, :username)
    end

    test "update_username/2 validates username format" do
      user = insert(:user)
      {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)

      # Invalid format
      assert {:error, changeset} = ProfileQueries.update_username(profile, "Invalid_Username")
      assert changeset.errors[:username] != nil
    end
  end
end
