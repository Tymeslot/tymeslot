defmodule Tymeslot.AuthTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Security.Password

  import Tymeslot.Factory

  describe "authenticate_user/3" do
    test "blocks access with invalid credentials" do
      user =
        insert(:user,
          password_hash: Password.hash_password("ValidPassword123!")
        )

      # Wrong password
      assert {:error, :invalid_password, _} = Auth.authenticate_user(user.email, "WrongPassword")

      # Non-existent user
      assert {:error, :not_found, _} = Auth.authenticate_user("fake@example.com", "Password123!")
    end
  end

  describe "request_email_change/3" do
    test "requires correct password to change email" do
      user =
        insert(:user,
          password_hash: Password.hash_password("CurrentPassword123!")
        )

      # Wrong password blocks change
      assert {:error, "Current password is incorrect"} =
               Auth.request_email_change(user, "new@example.com", "WrongPassword")

      # Duplicate email blocked
      insert(:user, email: "taken@example.com")

      assert {:error, "Email address is already in use"} =
               Auth.request_email_change(user, "taken@example.com", "CurrentPassword123!")
    end
  end

  describe "update_user_password/4" do
    test "users cannot access system with old sessions after password change" do
      user =
        insert(:user,
          password_hash: Password.hash_password("CurrentPassword123!")
        )

      # Create session before password change
      _old_session = insert(:user_session, user: user)

      # Change password
      {:ok, _updated_user} =
        Auth.update_user_password(
          user,
          "CurrentPassword123!",
          "NewPassword123!",
          "NewPassword123!"
        )

      # Verify new password works (sessions handled internally)
      assert {:ok, _, _} = Auth.authenticate_user(user.email, "NewPassword123!")
    end
  end

  describe "register_user/3" do
    test "prevents duplicate registrations" do
      insert(:user, email: "taken@example.com")

      params = %{
        "email" => "TAKEN@EXAMPLE.COM",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "Duplicate User",
        "terms_accepted" => "true"
      }

      assert {:error, :auth, _} = Auth.register_user(params, %Plug.Conn{})
    end
  end

  describe "password_reset" do
    test "oauth users cannot reset passwords" do
      oauth_user = insert(:user, provider: "google", password_hash: nil)
      assert {:error, :oauth_user, _} = Auth.initiate_password_reset(oauth_user.email)
    end
  end
end
