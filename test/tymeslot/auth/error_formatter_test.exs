defmodule Tymeslot.Auth.ErrorFormatterTest do
  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Ecto.Changeset
  alias Tymeslot.Auth.ErrorFormatter

  describe "format_auth_error/1" do
    test "returns string as is" do
      assert ErrorFormatter.format_auth_error("Custom error") == "Custom error"
    end

    test "formats generic auth errors" do
      Enum.each(
        [:invalid_input, :not_found, :invalid_password, :invalid_credentials],
        fn reason ->
          assert ErrorFormatter.format_auth_error(reason) == "Invalid email or password."
        end
      )
    end

    test "formats account status errors" do
      assert ErrorFormatter.format_auth_error(:account_throttled) =~ "Too many login attempts"
      assert ErrorFormatter.format_auth_error(:email_not_verified) =~ "verify your email"
    end

    test "formats rate limit errors" do
      assert ErrorFormatter.format_auth_error(:rate_limited) =~ "Too many attempts"
    end

    test "formats oauth errors" do
      assert ErrorFormatter.format_auth_error(:oauth_user) =~ "associated with a social login"
      assert ErrorFormatter.format_auth_error(:user_already_exists) =~ "already registered"
      assert ErrorFormatter.format_auth_error(:invalid_oauth_state) =~ "Authentication failed"
    end

    test "formats token errors" do
      assert ErrorFormatter.format_auth_error(:token_expired) =~ "link has expired"
      assert ErrorFormatter.format_auth_error(:invalid_token) =~ "link is invalid"
    end

    test "formats registration errors" do
      assert ErrorFormatter.format_auth_error(:profile_creation) =~ "profile setup failed"
      assert ErrorFormatter.format_auth_error(:verification) =~ "email verification failed"
      assert ErrorFormatter.format_auth_error(:registration_failed) =~ "Registration failed"
    end

    test "formats password reset errors" do
      assert ErrorFormatter.format_auth_error(:password_reset_failed) =~
               "Unable to reset password"
    end

    test "returns default message for unknown atom" do
      assert ErrorFormatter.format_auth_error(:unknown_reason) ==
               "An error occurred. Please try again."
    end
  end

  describe "format_validation_errors/1" do
    test "formats changeset errors" do
      data = %{}
      types = %{email: :string, name: :string}

      changeset =
        {data, types}
        |> Changeset.cast(%{email: "invalid"}, [:email, :name])
        |> Changeset.validate_required([:name])
        |> Changeset.add_error(:email, "is invalid")

      result = ErrorFormatter.format_validation_errors(changeset)
      assert result =~ "Email is invalid"
      assert result =~ "Name can't be blank"
    end

    test "formats error map" do
      errors = %{email: ["is invalid"], password: ["is too short"]}
      result = ErrorFormatter.format_validation_errors(errors)
      assert result =~ "Email is invalid"
      assert result =~ "Password is too short"
    end
  end

  describe "format_oauth_error/2" do
    test "formats specific oauth errors" do
      assert ErrorFormatter.format_oauth_error(:github, "access_denied") =~
               "Github authorization was denied"

      assert ErrorFormatter.format_oauth_error(:google, :invalid_response) =~
               "Invalid response from Google"

      assert ErrorFormatter.format_oauth_error(:github, :token_exchange_failed) =~
               "Failed to authenticate with Github"

      assert ErrorFormatter.format_oauth_error(:google, :other) =~ "Google authentication failed"
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
      assert ErrorFormatter.format_user_friendly_error(
               "registration",
               "email: has already been taken"
             ) ==
               "This email address is already registered. Please use a different email or try logging in."
    end

    test "formats email taken error for other operations" do
      assert ErrorFormatter.format_user_friendly_error("update", "email: has already been taken") ==
               "This email address is already in use. Please try with a different email."
    end

    test "formats general taken error" do
      assert ErrorFormatter.format_user_friendly_error(
               "registration",
               "username: has already been taken"
             ) ==
               "This information is already in use. Please try with different details."
    end

    test "formats password too short error" do
      assert ErrorFormatter.format_user_friendly_error("registration", "password is too short") ==
               "Password must be at least 8 characters long."
    end

    test "formats invalid email error" do
      assert ErrorFormatter.format_user_friendly_error("registration", "email is invalid") ==
               "Please enter a valid email address."
    end

    test "formats unknown string reason" do
      assert ErrorFormatter.format_user_friendly_error("registration", "something went wrong") ==
               "Registration failed: something went wrong"
    end

    test "formats non-string reason" do
      assert ErrorFormatter.format_user_friendly_error("registration", :unexpected_error) ==
               "Registration failed: :unexpected_error"
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

  describe "format_rate_limit_error/2" do
    test "formats with retry_after" do
      assert ErrorFormatter.format_rate_limit_error("login", 120) =~ "try again in 2 minute(s)"
      assert ErrorFormatter.format_rate_limit_error("login", 30) =~ "try again in 30 seconds"
    end

    test "formats without retry_after" do
      assert ErrorFormatter.format_rate_limit_error("login") =~ "try again later"
    end
  end
end
