defmodule Tymeslot.Auth.UserQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Repo

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

  describe "touch_last_active_at/1" do
    test "stamps last_active_at for the user" do
      user = insert(:user)
      assert is_nil(user.last_active_at)

      assert :ok == UserQueries.touch_last_active_at(user.id)

      assert %DateTime{} = Repo.reload!(user).last_active_at
    end

    test "only touches the given user" do
      user = insert(:user)
      other = insert(:user)

      UserQueries.touch_last_active_at(user.id)

      assert is_nil(Repo.reload!(other).last_active_at)
    end
  end
end
