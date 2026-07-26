defmodule Tymeslot.Profiles.ProfileQueriesUsernameTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Profiles.ProfileQueries
  import Tymeslot.Factory

  describe "username operations" do
    test "get_by_username/1 returns profile with matching username" do
      user = insert(:user)
      {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)
      username = "user_#{System.unique_integer([:positive])}"
      {:ok, updated} = ProfileQueries.update_username(profile, username)

      {:ok, found} = ProfileQueries.get_by_username(username)
      assert found.id == updated.id
      assert found.username == username
    end

    test "get_by_username/1 returns nil for non-existent username" do
      assert {:error, :not_found} ==
               ProfileQueries.get_by_username("nonexistent_#{System.unique_integer([:positive])}")
    end

    test "username_available?/1 returns true for available username" do
      assert ProfileQueries.username_available?("available_#{System.unique_integer([:positive])}")
    end

    test "username_available?/1 returns false for taken username" do
      user = insert(:user)
      {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)
      username = "taken_#{System.unique_integer([:positive])}"
      {:ok, _result} = ProfileQueries.update_username(profile, username)

      refute ProfileQueries.username_available?(username)
    end

    test "update_username/2 updates the username" do
      user = insert(:user)
      {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)

      assert is_nil(profile.username)

      username = "newuser_#{System.unique_integer([:positive])}"
      {:ok, updated} = ProfileQueries.update_username(profile, username)
      assert updated.username == username

      # Verify it's persisted
      {:ok, found} = ProfileQueries.get_by_user_id(user.id)
      assert found.username == username
    end

    test "update_username/2 enforces uniqueness at database level" do
      user1 = insert(:user)
      user2 = insert(:user)

      {:ok, profile1} = ProfileQueries.get_or_create_by_user_id(user1.id)
      {:ok, profile2} = ProfileQueries.get_or_create_by_user_id(user2.id)

      username = "dup_#{System.unique_integer([:positive])}"
      {:ok, _result} = ProfileQueries.update_username(profile1, username)

      # This should fail due to unique constraint
      assert {:error, changeset} = ProfileQueries.update_username(profile2, username)
      assert Keyword.has_key?(changeset.errors, :username)
    end

    test "update_username/2 validates username format" do
      user = insert(:user)
      {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)

      # Invalid format
      assert {:error, changeset} = ProfileQueries.update_username(profile, "Invalid_Username")
      assert {message, _opts} = changeset.errors[:username]
      assert message =~ "only lowercase letters"
    end
  end
end
