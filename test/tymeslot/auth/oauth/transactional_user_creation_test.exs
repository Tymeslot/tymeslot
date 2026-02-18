defmodule Tymeslot.Auth.OAuth.TransactionalUserCreationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  use ExUnitProperties

  alias Tymeslot.Auth.OAuth.TransactionalUserCreation
  alias Tymeslot.DatabaseSchemas.UserSchema
  alias Tymeslot.Repo
  import Tymeslot.Factory

  describe "create_oauth_user_transactionally/2" do
    test "successfully creates a user and profile" do
      auth_params = %{
        "email" => "new_oauth_user@example.com",
        "provider" => "github",
        "github_user_id" => "12345",
        "is_verified" => true,
        "terms_accepted" => "true"
      }

      profile_params = %{full_name: "OAuth User"}

      assert {:ok, %{user: user, profile: profile}} =
               TransactionalUserCreation.create_oauth_user_transactionally(
                 auth_params,
                 profile_params
               )

      assert user.email == "new_oauth_user@example.com"
      assert user.provider == "github"
      assert user.github_user_id == "12345"
      assert profile.user_id == user.id
      assert profile.full_name == "OAuth User"
    end

    test "fails if user with email already exists" do
      existing_user = insert(:user, email: "existing@example.com")

      auth_params = %{
        "email" => existing_user.email,
        "provider" => "google",
        "google_user_id" => "67890"
      }

      profile_params = %{full_name: "Another Name"}

      assert {:error, :user_already_exists, _reason} =
               TransactionalUserCreation.create_oauth_user_transactionally(
                 auth_params,
                 profile_params
               )
    end
  end

  describe "find_or_create_oauth_user/3" do
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
        "provider" => "google"
      }

      assert {:ok, %{user: user, created: false}} =
               TransactionalUserCreation.find_or_create_oauth_user(:google, auth_params)

      assert user.id == existing_user.id
      assert user.google_user_id == "333"
    end
  end

  describe "find_or_create_oauth_user/3 property tests" do
    property "never creates duplicate users with same email or provider_id" do
      check all(
              email <- StreamData.string(:alphanumeric, min_length: 5),
              provider_id <- StreamData.string(:alphanumeric, min_length: 5),
              provider <- StreamData.member_of([:github, :google])
            ) do
        email = "#{email}@test.com"

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
