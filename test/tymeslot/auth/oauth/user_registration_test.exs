defmodule Tymeslot.Auth.OAuth.UserRegistrationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Tymeslot.Auth.OAuth.UserRegistration
  alias Tymeslot.Auth.{UserQueries, UserSchema}
  alias Tymeslot.Factory
  alias Tymeslot.Repo

  describe "find_existing_user/2" do
    test ":oauth finds user by provider and provider_uid" do
      user = Factory.insert(:user, provider: "oauth", provider_uid: "sub-abc")

      assert {:ok, found} =
               UserRegistration.find_existing_user(:oauth, %{
                 provider_uid: "sub-abc",
                 email: "other@example.com",
                 is_verified: true
               })

      assert found.id == user.id
    end

    test ":oauth never signs in by email; a registered email is reported as taken" do
      _user = Factory.insert(:user, email: "existing@example.com")

      assert {:error, :email_already_taken} =
               UserRegistration.find_existing_user(:oauth, %{
                 provider_uid: "non-existent-uid",
                 email: "existing@example.com",
                 is_verified: true
               })
    end

    test ":github does not sign into an account created with Google" do
      _google_account =
        Factory.insert(:user,
          email: "google-user@example.com",
          provider: "google",
          google_user_id: "google-id"
        )

      assert {:error, :email_already_taken} =
               UserRegistration.find_existing_user(:github, %{
                 github_user_id: 4242,
                 email: "google-user@example.com",
                 is_verified: true
               })
    end

    test ":oauth returns :not_found when neither uid nor email match" do
      assert {:error, :not_found} =
               UserRegistration.find_existing_user(:oauth, %{
                 provider_uid: "unknown-uid",
                 email: "nonexistent@example.com",
                 is_verified: true
               })
    end
  end

  describe "check_oauth_account_linking/3 via create_oauth_user" do
    test ":oauth links account when provider_uid matches existing user" do
      existing =
        Factory.insert(:user,
          email: "sso@example.com",
          provider: "oauth",
          provider_uid: "uid-match"
        )

      oauth_user = %{
        email: "sso@example.com",
        provider_uid: "uid-match",
        name: "SSO User",
        is_verified: true,
        email_from_provider: true
      }

      assert {:ok, user} = UserRegistration.create_oauth_user(:oauth, oauth_user)
      assert user.id == existing.id
    end

    test ":oauth does NOT link account by email even when the email is verified" do
      existing =
        Factory.insert(:user,
          email: "sso@example.com",
          provider: "oauth",
          provider_uid: "uid-old"
        )

      oauth_user = %{
        email: "sso@example.com",
        provider_uid: "uid-different",
        name: "SSO User",
        is_verified: true,
        email_from_provider: true
      }

      assert {:error, _reason} = UserRegistration.create_oauth_user(:oauth, oauth_user)
      assert Repo.get!(UserSchema, existing.id).provider_uid == "uid-old"
    end

    test ":oauth does NOT link account by email when email is unverified" do
      _existing =
        Factory.insert(:user,
          email: "sso@example.com",
          provider: "oauth",
          provider_uid: "uid-old"
        )

      oauth_user = %{
        email: "sso@example.com",
        provider_uid: "uid-different",
        name: "SSO User",
        is_verified: false,
        email_from_provider: false
      }

      # A different provider_uid means a different account: creating it fails
      # on the email uniqueness constraint, preventing account takeover.
      assert {:error, _changeset} = UserRegistration.create_oauth_user(:oauth, oauth_user)
    end
  end

  describe "account linking for GitHub/Google via create_oauth_user" do
    test ":github does NOT link a different GitHub account by email" do
      existing =
        Factory.insert(:user,
          email: "gh@example.com",
          provider: "github",
          github_user_id: "111"
        )

      oauth_user = %{
        email: "gh@example.com",
        github_user_id: "222",
        name: "Other User",
        is_verified: true,
        email_from_provider: true
      }

      assert {:error, _reason} = UserRegistration.create_oauth_user(:github, oauth_user)
      assert Repo.get!(UserSchema, existing.id).github_user_id == "111"
    end

    test ":google does NOT link a different Google account by email" do
      existing =
        Factory.insert(:user,
          email: "goog@example.com",
          provider: "google",
          google_user_id: "aaa"
        )

      oauth_user = %{
        email: "goog@example.com",
        google_user_id: "bbb",
        name: "Other User",
        is_verified: true,
        email_from_provider: true
      }

      assert {:error, _reason} = UserRegistration.create_oauth_user(:google, oauth_user)
      assert Repo.get!(UserSchema, existing.id).google_user_id == "aaa"
    end

    test ":github links account when github_user_id matches" do
      existing =
        Factory.insert(:user,
          email: "gh@example.com",
          provider: "github",
          github_user_id: "111"
        )

      oauth_user = %{
        email: "gh@example.com",
        github_user_id: "111",
        name: "Same User",
        is_verified: true,
        email_from_provider: true
      }

      assert {:ok, user} = UserRegistration.create_oauth_user(:github, oauth_user)
      assert user.id == existing.id
    end

    test ":github with unverified email and no matching provider_id fails on uniqueness" do
      _existing =
        Factory.insert(:user,
          email: "gh@example.com",
          provider: "github",
          github_user_id: "111"
        )

      oauth_user = %{
        email: "gh@example.com",
        github_user_id: "222",
        name: "Attacker",
        is_verified: false,
        email_from_provider: false
      }

      assert {:error, _reason} = UserRegistration.create_oauth_user(:github, oauth_user)
    end
  end

  describe "normalize_github_id (via find_existing_user)" do
    test "handles non-integer string GitHub ID gracefully" do
      # The function should not crash on "abc": it returns nil and skips the ID lookup
      result =
        UserRegistration.find_existing_user(:github, %{
          email: "nobody@example.com",
          github_user_id: "abc"
        })

      assert {:error, :not_found} = result
    end
  end

  describe "UserQueries.get_user_by_provider/3" do
    test "finds user by provider and provider_uid" do
      user = Factory.insert(:user, provider: "oauth", provider_uid: "query-test-uid")

      assert {:ok, found} = UserQueries.get_user_by_provider("oauth", "query-test-uid")
      assert found.id == user.id
    end

    test "returns :not_found for non-existent provider_uid" do
      assert {:error, :not_found} = UserQueries.get_user_by_provider("oauth", "nonexistent")
    end
  end
end
