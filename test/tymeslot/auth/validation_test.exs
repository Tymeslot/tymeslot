defmodule Tymeslot.Auth.ValidationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Ecto.Changeset
  alias Tymeslot.Auth.Validation

  describe "validate_login_input/1" do
    test "returns ok with sanitized params when email and password are valid" do
      params = %{"email" => "test@example.com", "password" => "password123"}
      assert {:ok, result} = Validation.validate_login_input(params)
      assert result["password"] == "password123"
    end

    test "returns error when email is missing or blank" do
      assert {:error, %{email: _email_error}} =
               Validation.validate_login_input(%{"password" => "password123"})

      assert {:error, %{email: _email_error}} =
               Validation.validate_login_input(%{"email" => "", "password" => "password123"})
    end

    test "returns error when password is missing or blank" do
      assert {:error, %{password: "can't be blank"}} =
               Validation.validate_login_input(%{"email" => "test@example.com"})

      assert {:error, %{password: "can't be blank"}} =
               Validation.validate_login_input(%{
                 "email" => "test@example.com",
                 "password" => ""
               })
    end

    test "returns error when password exceeds 1024 bytes" do
      long_password = String.duplicate("a", 1025)

      assert {:error, %{password: "Password is too long"}} =
               Validation.validate_login_input(%{
                 "email" => "test@example.com",
                 "password" => long_password
               })
    end

    test "returns errors for both fields when both are missing" do
      {:error, errors} = Validation.validate_login_input(%{})
      assert Map.has_key?(errors, :email)
      assert Map.has_key?(errors, :password)
    end
  end

  describe "delegated functions" do
    test "validate_signup_input/1 delegates to AuthValidation" do
      # We just check if it returns something expected from AuthValidation
      # Since we don't want to mock internal modules, we just test the integration
      params = %{"email" => "invalid"}
      assert {:error, _reason} = Validation.validate_signup_input(params)
    end

    test "validate_password_reset_input/1 delegates to AuthValidation" do
      params = %{"email" => "invalid"}
      assert {:error, _reason} = Validation.validate_password_reset_input(params)
    end

    test "validate_new_password_input/1 delegates to AuthValidation" do
      params = %{"password" => "short"}
      assert {:error, _reason} = Validation.validate_new_password_input(params)
    end
  end

  describe "format_validation_errors/1" do
    test "formats map errors" do
      errors = %{email: ["is invalid"]}
      assert Validation.format_validation_errors(errors) == "Email is invalid"
    end

    test "formats {:error, map} errors" do
      errors = {:error, %{email: ["is invalid"]}}
      assert Validation.format_validation_errors(errors) == "Email is invalid"
    end

    test "formats changeset errors" do
      changeset =
        {%{}, %{email: :string}}
        |> Changeset.change(%{email: "invalid"})
        |> Changeset.validate_format(:email, ~r/@/)

      assert Validation.format_validation_errors(changeset) == "Email has invalid format"
    end

    test "returns default message for unknown error format" do
      assert Validation.format_validation_errors(nil) == "Invalid input provided."
    end
  end
end
