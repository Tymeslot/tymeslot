defmodule Tymeslot.Auth.OAuth.TransactionalUserCreationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  use ExUnitProperties

  alias Tymeslot.Auth.OAuth.TransactionalUserCreation
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Availability.WeeklyAvailabilityQueries
  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.Profiles.{ProfileQueries, ProfileSchema}
  alias Tymeslot.Repo
  import Tymeslot.Factory

  describe "find_or_create_oauth_user/4" do
    test "creates new user if not found by provider id or email" do
      auth_params = %{
        "email" => "fresh@example.com",
        "github_user_id" => "111",
        "provider" => "github",
        "is_verified" => true
      }

      assert {:ok, %{user: user, created: true}} =
               TransactionalUserCreation.find_or_create_oauth_user(:github, auth_params)

      assert user.email == "fresh@example.com"
      assert user.github_user_id == "111"
    end

    test "finds existing user by provider id" do
      existing_user = insert(:user, github_user_id: "222", provider: "github")

      auth_params = %{
        "email" => "different@example.com",
        "github_user_id" => "222",
        "provider" => "github"
      }

      assert {:ok, %{user: user, created: false}} =
               TransactionalUserCreation.find_or_create_oauth_user(:github, auth_params)

      assert user.id == existing_user.id
    end

    test "links provider to existing user by email" do
      existing_user = insert(:user, email: "link@example.com", provider: "local")

      auth_params = %{
        "email" => "link@example.com",
        "google_user_id" => "333",
        "provider" => "google",
        "is_verified" => true
      }

      assert {:ok, %{user: user, created: false}} =
               TransactionalUserCreation.find_or_create_oauth_user(:google, auth_params)

      assert user.id == existing_user.id
      assert user.google_user_id == "333"
    end
  end

  describe "find_or_create_oauth_user/4 weekly schedule" do
    test "creates default weekly schedule for new OAuth user" do
      auth_params = %{
        "email" => "new-oauth@example.com",
        "google_user_id" => "google-uid-schedule-test",
        "provider" => "google",
        "is_verified" => true
      }

      assert {:ok, %{user: user}} =
               TransactionalUserCreation.find_or_create_oauth_user(:google, auth_params)

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)

      schedules = WeeklyAvailabilityQueries.get_weekly_availability_by_profile(profile.id)

      assert length(schedules) == 7,
             "Expected 7 days of weekly availability for OAuth user, got #{length(schedules)}"
    end

    test "creates profile and default schedule for existing user without a profile" do
      existing_user = insert(:user, email: "no-profile@example.com", provider: "local")

      auth_params = %{
        "email" => "no-profile@example.com",
        "google_user_id" => "google-uid-no-profile",
        "provider" => "google",
        "is_verified" => true
      }

      assert {:ok, %{user: user, created: false}} =
               TransactionalUserCreation.find_or_create_oauth_user(:google, auth_params)

      assert user.id == existing_user.id

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)

      schedules = WeeklyAvailabilityQueries.get_weekly_availability_by_profile(profile.id)

      assert length(schedules) == 7,
             "Expected 7 days of weekly availability for existing user without profile, got #{length(schedules)}"
    end

    test "rolls back weekly schedule rows when user creation fails" do
      # Pre-insert a user with a known email so a second creation attempt with the
      # same address (unverified, to skip the link-by-email path) triggers a DB
      # unique-constraint violation and rolls the whole transaction back.
      existing_user = insert(:user, email: "rollback-test@example.com")

      user_count_before =
        Repo.aggregate(from(u in UserSchema, where: u.id != ^existing_user.id), :count)

      # Count schedule rows scoped to profiles owned by the target email's user.
      # The pre-existing user has no profile, so this is 0 before and must remain
      # 0 after a rolled-back attempt — directly tied to the data under test.
      rollback_email = "rollback-test@example.com"

      scoped_schedule_count = fn ->
        Repo.aggregate(
          from(wa in WeeklyAvailabilitySchema,
            join: p in ProfileSchema,
            on: wa.profile_id == p.id,
            join: u in UserSchema,
            on: p.user_id == u.id,
            where: u.email == ^rollback_email
          ),
          :count
        )
      end

      schedule_count_before = scoped_schedule_count.()

      auth_params = %{
        "email" => rollback_email,
        "github_user_id" => "github-uid-rollback-test",
        "provider" => "github",
        # Unverified so the email-link path is skipped and a new user insert is attempted
        "is_verified" => false
      }

      assert {:error, _reason} =
               TransactionalUserCreation.find_or_create_oauth_user(:github, auth_params)

      user_count_after =
        Repo.aggregate(from(u in UserSchema, where: u.id != ^existing_user.id), :count)

      schedule_count_after = scoped_schedule_count.()

      assert user_count_after == user_count_before,
             "Expected no new users after rollback"

      assert schedule_count_after == schedule_count_before,
             "Expected no orphaned weekly schedule rows after rollback"
    end
  end

  describe "find_or_create_oauth_user/4 property tests" do
    property "never creates duplicate users with same email or provider_id" do
      check all(
              email <- StreamData.string(:alphanumeric, min_length: 5),
              provider_id <- StreamData.string(:alphanumeric, min_length: 5),
              unique_prefix <- StreamData.positive_integer(),
              provider <- StreamData.member_of([:github, :google])
            ) do
        email = String.downcase("#{unique_prefix}_#{email}@test.com")

        auth_params = %{
          "email" => email,
          "provider" => to_string(provider),
          "#{provider}_user_id" => provider_id,
          "is_verified" => true
        }

        # First call creates the user
        assert {:ok, %{user: user1, created: true}} =
                 TransactionalUserCreation.find_or_create_oauth_user(provider, auth_params)

        # Second call with identical params returns same user, not created
        assert {:ok, %{user: user2, created: false}} =
                 TransactionalUserCreation.find_or_create_oauth_user(provider, auth_params)

        assert user1.id == user2.id

        # Third call with same email but different provider links to same user
        other_provider = if provider == :github, do: :google, else: :github
        other_provider_id = "#{provider_id}_other"

        other_auth_params = %{
          "email" => email,
          "provider" => to_string(other_provider),
          "#{other_provider}_user_id" => other_provider_id,
          "is_verified" => true
        }

        assert {:ok, %{user: user3, created: false}} =
                 TransactionalUserCreation.find_or_create_oauth_user(
                   other_provider,
                   other_auth_params
                 )

        assert user1.id == user3.id

        # Count users in DB for this email - should be exactly 1
        assert Repo.aggregate(
                 from(u in UserSchema, where: u.email == ^email),
                 :count
               ) == 1
      end
    end
  end
end
