defmodule Tymeslot.Auth.OAuth.UserRegistrationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Tymeslot.Auth.OAuth.UserRegistration
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Factory

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

    test ":oauth falls back to email when provider_uid not found and email is verified" do
      user = Factory.insert(:user, email: "existing@example.com")

      assert {:ok, found} =
               UserRegistration.find_existing_user(:oauth, %{
                 provider_uid: "non-existent-uid",
                 email: "existing@example.com",
                 is_verified: true
               })

      assert found.id == user.id
    end

    test ":oauth does NOT fall back to email when is_verified is false" do
      _user = Factory.insert(:user, email: "existing@example.com")

      assert {:error, :not_found} =
               UserRegistration.find_existing_user(:oauth, %{
                 provider_uid: "non-existent-uid",
                 email: "existing@example.com",
                 is_verified: false
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

    test ":oauth links account by email when provider_uid differs but email is verified" do
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

      # TransactionalUserCreation updates the existing user's provider_uid when linking
      assert {:ok, user} = UserRegistration.create_oauth_user(:oauth, oauth_user)
      assert user.id == existing.id
      assert user.provider_uid == "uid-different"
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

      # With unverified email and different provider_uid, the system skips
      # email-based linking and tries to create a new user — which correctly
      # fails on the email uniqueness constraint, preventing account takeover.
      assert {:error, _changeset} = UserRegistration.create_oauth_user(:oauth, oauth_user)
    end
  end

  describe "account linking for GitHub/Google via create_oauth_user" do
    test ":github links account by email and updates github_user_id" do
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

      assert {:ok, user} = UserRegistration.create_oauth_user(:github, oauth_user)
      assert user.id == existing.id
      assert user.github_user_id == "222"
    end

    test ":google links account by email and updates google_user_id" do
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

      assert {:ok, user} = UserRegistration.create_oauth_user(:google, oauth_user)
      assert user.id == existing.id
      assert user.google_user_id == "bbb"
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

  describe "registration_complete?/2" do
    test ":github requires non-empty email and github_user_id" do
      assert UserRegistration.registration_complete?(:github, %{
               email: "a@b.com",
               github_user_id: "123"
             })

      refute UserRegistration.registration_complete?(:github, %{
               email: "",
               github_user_id: "123"
             })

      refute UserRegistration.registration_complete?(:github, %{
               email: "a@b.com",
               github_user_id: ""
             })
    end

    test ":google requires non-empty email and google_user_id" do
      assert UserRegistration.registration_complete?(:google, %{
               email: "a@b.com",
               google_user_id: "123"
             })

      refute UserRegistration.registration_complete?(:google, %{
               email: "",
               google_user_id: "123"
             })
    end

    test ":oauth requires non-empty email and provider_uid" do
      assert UserRegistration.registration_complete?(:oauth, %{
               email: "a@b.com",
               provider_uid: "sub-1"
             })

      refute UserRegistration.registration_complete?(:oauth, %{
               email: "",
               provider_uid: "sub-1"
             })

      refute UserRegistration.registration_complete?(:oauth, %{
               email: "a@b.com",
               provider_uid: ""
             })
    end

    test "unknown provider returns false" do
      refute UserRegistration.registration_complete?(:unknown, %{email: "a@b.com"})
    end
  end

  describe "normalize_github_id (via find_existing_user)" do
    test "handles non-integer string GitHub ID gracefully" do
      # The function should not crash on "abc" — it returns nil, leading to email fallback
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
