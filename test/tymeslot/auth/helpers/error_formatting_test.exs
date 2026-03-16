defmodule Tymeslot.Auth.Helpers.ErrorFormattingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Ecto.Changeset
  alias Tymeslot.Auth.ErrorFormatter

  describe "format_validation_errors/1" do
    test "formats a map of errors into a string" do
      errors = %{email: "can't be blank", password: "too short"}
      result = ErrorFormatter.format_validation_errors(errors)
      assert result =~ "Email can't be blank"
      assert result =~ "Password too short"
    end
  end

  describe "format_changeset_errors/1" do
    test "formats Ecto changeset errors" do
      changeset = %Changeset{
        data: %{},
        errors: [email: {"has already been taken", [validation: :unsafe]}]
      }

      assert ErrorFormatter.format_changeset_errors(changeset) == "Email has already been taken"
    end

    test "interpolates options in error messages" do
      changeset = %Changeset{
        data: %{},
        errors: [
          password:
            {"should be at least %{count} characters",
             [count: 8, validation: :length, kind: :min]}
        ]
      }

      assert ErrorFormatter.format_changeset_errors(changeset) ==
               "Password should be at least 8 characters"
    end
  end

  describe "format_user_friendly_error/2" do
    test "formats email taken error for registration" do
      reason = "email: has already been taken"

      assert ErrorFormatter.format_user_friendly_error("registration", reason) ==
               "This email address is already registered. Please use a different email or try logging in."
    end

    test "formats email taken error for other operations" do
      reason = "email: has already been taken"

      assert ErrorFormatter.format_user_friendly_error("update", reason) ==
               "This email address is already in use. Please try with a different email."
    end

    test "formats general taken error" do
      reason = "username: has already been taken"

      assert ErrorFormatter.format_user_friendly_error("registration", reason) ==
               "This information is already in use. Please try with different details."
    end

    test "formats password too short error" do
      reason = "password is too short"

      assert ErrorFormatter.format_user_friendly_error("registration", reason) ==
               "Password must be at least 8 characters long."
    end

    test "formats invalid email error" do
      reason = "email is invalid"

      assert ErrorFormatter.format_user_friendly_error("registration", reason) ==
               "Please enter a valid email address."
    end

    test "formats unknown string reason" do
      reason = "something went wrong"

      assert ErrorFormatter.format_user_friendly_error("registration", reason) ==
               "Registration failed: something went wrong"
    end

    test "formats non-string reason" do
      reason = :unexpected_error

      assert ErrorFormatter.format_user_friendly_error("registration", reason) ==
               "Registration failed: :unexpected_error"
    end
  end

  describe "format_auth_error/1" do
    test "formats common auth error atoms" do
      assert ErrorFormatter.format_auth_error(:not_found) == "Invalid email or password."
      assert ErrorFormatter.format_auth_error(:invalid_password) == "Invalid email or password."

      assert ErrorFormatter.format_auth_error(:rate_limit_exceeded) ==
               "Too many attempts. Please try again later."

      assert ErrorFormatter.format_auth_error(:other) == "An error occurred. Please try again."
    end
  end

  describe "format_verification_error/1" do
    test "formats verification error atoms" do
      assert ErrorFormatter.format_verification_error(:invalid_token) ==
               "Invalid verification token. Please request a new verification email."

      assert ErrorFormatter.format_verification_error(:token_expired) ==
               "Your verification token has expired. Please request a new verification email."

      assert ErrorFormatter.format_verification_error(:rate_limited) ==
               "Too many verification attempts. Please try again later."

      assert ErrorFormatter.format_verification_error(:email_send_failed) ==
               "Failed to send verification email. Please try again later."

      assert ErrorFormatter.format_verification_error(:other) ==
               "Verification failed. Please try again."
    end
  end

  describe "format_password_reset_error/1" do
    test "formats password reset error atoms" do
      assert ErrorFormatter.format_password_reset_error(:user_not_found) ==
               "If your email is registered, you will receive password reset instructions."

      assert ErrorFormatter.format_password_reset_error(:oauth_user) ==
               "You cannot reset your password because your account is managed by an external authentication provider."

      assert ErrorFormatter.format_password_reset_error(:invalid_token) ==
               "Invalid or expired password reset token."

      assert ErrorFormatter.format_password_reset_error(:rate_limited) ==
               "Too many password reset attempts. Please try again later."

      assert ErrorFormatter.format_password_reset_error(:other) ==
               "Password reset failed. Please try again."
    end
  end
end
