defmodule Tymeslot.DatabaseQueries.ProfileQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.ProfileQueries

  describe "get_or_create_by_user_id/1" do
    test "applies correct business defaults for new user profiles" do
      user = insert(:user)

      assert {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)

      # These are business rules, not framework behavior
      assert profile.timezone == "Europe/Kyiv"
      assert profile.buffer_minutes == 15
      assert profile.advance_booking_days == 90
      assert profile.min_advance_hours == 3
    end

    test "prevents duplicate profiles per user" do
      existing_profile = insert(:profile)
      # Reload to get the user_id that was auto-created
      existing_profile = ProfileQueries.get_profile!(existing_profile.id)

      assert {:ok, profile} = ProfileQueries.get_or_create_by_user_id(existing_profile.user_id)
      assert profile.id == existing_profile.id
    end
  end

  describe "update_profile/2" do
    test "validates timezone against business rules" do
      profile = insert(:profile)

      assert {:error, changeset} =
               ProfileQueries.update_profile(profile, %{timezone: "Invalid/Zone"})

      refute changeset.valid?
      assert "is not a valid timezone" in errors_on(changeset).timezone
    end

    test "enforces buffer time business constraints" do
      profile = insert(:profile)

      assert {:error, changeset} = ProfileQueries.update_field(profile, :buffer_minutes, -10)
      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).buffer_minutes
    end
  end

  describe "public booking page business logic" do
    test "only shows active meeting types to visitors" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "scheduler")

      insert(:meeting_type, user: user, name: "15 min", is_active: true)
      insert(:meeting_type, user: user, name: "30 min", is_active: true)
      insert(:meeting_type, user: user, name: "Disabled", is_active: false)

      {:ok, result} = ProfileQueries.get_by_username_with_context("scheduler")

      assert length(result.meeting_types) == 2
      meeting_names = Enum.map(result.meeting_types, & &1.name)
      assert "15 min" in meeting_names
      assert "30 min" in meeting_names
      refute "Disabled" in meeting_names
    end

    test "handles non-existent users gracefully for public pages" do
      result = ProfileQueries.get_by_username_with_context("nonexistent")
      assert result == {:error, :not_found}
    end
  end
end
