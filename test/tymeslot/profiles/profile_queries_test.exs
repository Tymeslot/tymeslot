defmodule Tymeslot.Profiles.ProfileQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  describe "get_or_create_by_user_id/1" do
    test "applies correct business defaults for new user profiles" do
      user = insert(:user)

      assert {:ok, profile} = ProfileQueries.get_or_create_by_user_id(user.id)

      # These are business rules, not framework behavior. The scheduling
      # policy now belongs to the profile's default availability schedule.
      assert is_nil(profile.timezone)

      assert {:ok, schedule} = Schedules.create_default(profile.id)
      assert schedule.buffer_minutes == 15
      assert schedule.advance_booking_days == 90
      assert schedule.min_advance_hours == 3
    end

    test "prevents duplicate profiles per user" do
      existing_profile = insert(:profile)
      # Reload to get the user_id that was auto-created
      existing_profile = ProfileQueries.get_with_user(existing_profile.id)

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

    test "enforces buffer time business constraints on the profile's schedule" do
      profile = insert(:profile)
      schedule = insert(:availability_schedule, profile: profile, is_default: true)

      assert {:error, changeset} = Schedules.update_policy(schedule, %{buffer_minutes: -10})
      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).buffer_minutes
    end
  end

  describe "set_primary_calendar_integration/2" do
    test "returns a changeset error when the integration no longer exists" do
      # A primary candidate can be deleted between being chosen and being
      # written, so the foreign key has to come back as an error the caller
      # can recover from, not as a raise that takes the deletion down with it.
      profile = insert(:profile)
      integration = insert(:calendar_integration, user: profile.user)
      Repo.delete!(integration)

      assert {:error, changeset} =
               ProfileQueries.set_primary_calendar_integration(profile.user_id, integration.id)

      assert "does not exist" in errors_on(changeset).primary_calendar_integration_id
    end
  end

  describe "get_by_username_with_user/1" do
    test "returns profile with preloaded user" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "scheduler")

      {:ok, result} = ProfileQueries.get_by_username_with_user("scheduler")

      assert result.username == "scheduler"
      assert result.user.id == user.id
    end

    test "handles non-existent users gracefully" do
      result = ProfileQueries.get_by_username_with_user("nonexistent")
      assert result == {:error, :not_found}
    end
  end
end
