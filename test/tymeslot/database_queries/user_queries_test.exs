defmodule Tymeslot.DatabaseQueries.UserQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Security.Password

  describe "authentication security (protects user accounts)" do
    test "validates password correctly for legitimate users" do
      user =
        insert(:user,
          email: "secure@example.com",
          password_hash: Password.hash_password("SecurePassword123!")
        )

      {:ok, authenticated_user} =
        UserQueries.get_user_by_email_and_password("secure@example.com", "SecurePassword123!")

      assert authenticated_user.id == user.id
    end

    test "prevents unauthorized access with wrong password" do
      insert(:user,
        email: "secure@example.com",
        password_hash: Password.hash_password("SecurePassword123!")
      )

      unauthorized_attempt =
        UserQueries.get_user_by_email_and_password("secure@example.com", "WrongPassword!")

      assert unauthorized_attempt == {:error, :invalid_credentials}
    end
  end

  describe "social authentication security" do
    test "prevents provider impersonation with strict matching" do
      insert(:user, provider: "google", provider_uid: "google-123")

      # Wrong provider
      assert {:error, :not_found} == UserQueries.get_user_by_provider("facebook", "google-123")
      # Wrong uid
      assert {:error, :not_found} == UserQueries.get_user_by_provider("google", "facebook-123")
    end
  end

  describe "user registration security" do
    test "prevents duplicate email registrations" do
      insert(:user, email: "existing@example.com")

      duplicate_attempt = %{
        email: "existing@example.com",
        password: "Password123!",
        password_confirmation: "Password123!"
      }

      {:error, changeset} = UserQueries.create_user(duplicate_attempt)
      assert "has already been taken" in errors_on(changeset).email
    end

    test "securely hashes passwords during registration" do
      attrs = %{
        email: "secure@example.com",
        password: "SecurePassword123!",
        password_confirmation: "SecurePassword123!",
        name: "Secure User"
      }

      {:ok, user} = UserQueries.create_user(attrs)

      # Password should be hashed, not stored in plain text
      assert user.password_hash
      refute user.password_hash == "SecurePassword123!"
    end
  end

  describe "social registration security" do
    test "prevents provider account hijacking" do
      insert(:user, provider: "google", provider_uid: "existing-123")

      hijack_attempt = %{
        email: "hacker@example.com",
        provider: "google",
        provider_uid: "existing-123"
      }

      {:error, changeset} = UserQueries.create_social_user(hijack_attempt)
      assert "has already been taken" in errors_on(changeset).provider
    end
  end

  describe "email verification security" do
    test "secures account by clearing verification token after use" do
      user = insert(:user, verified_at: nil, verification_token: "one-time-token")

      {:ok, verified} = UserQueries.verify_user(user)

      # Token should be cleared to prevent reuse
      assert verified.verified_at
      assert verified.verification_token == nil
    end
  end

  describe "password reset security" do
    test "secures reset process by clearing tokens after use" do
      user =
        insert(:user, reset_token_hash: "one-time-reset-hash", reset_sent_at: DateTime.utc_now())

      reset_attrs = %{
        password: "NewSecurePassword123!",
        password_confirmation: "NewSecurePassword123!"
      }

      {:ok, updated} = UserQueries.reset_password(user, reset_attrs)

      # Tokens should be cleared to prevent token reuse attacks
      assert updated.reset_token_hash == nil
      assert updated.reset_sent_at == nil

      # New password should work
      assert UserQueries.get_user_by_email_and_password(user.email, "NewSecurePassword123!")
    end

    test "enforces strong password requirements" do
      user = insert(:user)

      weak_password = %{
        password: "weak",
        password_confirmation: "weak"
      }

      {:error, changeset} = UserQueries.reset_password(user, weak_password)
      refute changeset.valid?
    end
  end
end
