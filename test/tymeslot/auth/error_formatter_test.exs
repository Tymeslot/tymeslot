defmodule Tymeslot.Auth.ErrorFormatterTest do
  @moduletag :auth
  use Tymeslot.DataCase, async: true

  alias Ecto.Changeset
  alias Tymeslot.Auth.ErrorFormatter

  describe "format_auth_error/1" do
  @moduletag :auth
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
      assert ErrorFormatter.format_auth_error(:account_locked) =~ "account has been locked"
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
