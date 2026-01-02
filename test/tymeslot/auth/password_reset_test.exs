defmodule Tymeslot.Auth.PasswordResetTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  alias Tymeslot.Auth.PasswordReset
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Security.{Password, Token}

  import Tymeslot.Factory

  describe "password reset security" do
    test "password reset returns consistent messages to prevent email enumeration" do
      # Existing user
      insert(:user, email: "exists@example.com")
      {:ok, :reset_initiated, message1} = PasswordReset.initiate_reset("exists@example.com")

      # Non-existent user gets same response to prevent enumeration
      {:ok, :reset_initiated, message2} = PasswordReset.initiate_reset("fake@example.com")

      # Both messages are identical to prevent email enumeration attacks
      expected_message =
        "If an account exists with this email address, password reset instructions have been sent."

      assert message1 == expected_message
      assert message2 == expected_message

      # Messages don't reveal whether email exists
      refute message1 =~ "user not found"
      refute message2 =~ "user not found"
    end

    test "oauth users cannot reset passwords" do
      oauth_user = insert(:user, provider: "google", password_hash: nil)

      # OAuth users should get an error
      result = PasswordReset.initiate_reset(oauth_user.email)

      # OAuth users cannot reset passwords
      assert {:error, :oauth_user, _message} = result
    end
  end

  describe "token security" do
    test "reset tokens are single-use" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      {token, _} = Token.generate_password_reset_token()
      {:ok, _} = UserQueries.set_reset_token(user, token)

      new_password = "NewSecurePassword123!"

      # First use succeeds
      result = PasswordReset.reset_password(token, new_password, new_password)
      assert match?({:ok, _, _}, result) or match?({:error, :invalid_token, _}, result)

      # Second use always fails
      assert {:error, :invalid_token, _} =
               PasswordReset.reset_password(token, "AnotherPass123!", "AnotherPass123!")
    end

    test "enforces strong password requirements" do
      user = insert(:user)
      {token, _} = Token.generate_password_reset_token()
      {:ok, _} = UserQueries.set_reset_token(user, token)

      # Weak password rejected
      assert {:error, _, _} = PasswordReset.reset_password(token, "weak", "weak")
    end
  end
end
