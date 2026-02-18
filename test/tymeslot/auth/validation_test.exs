defmodule Tymeslot.Auth.ValidationTest do
  @moduletag :auth
  use Tymeslot.DataCase, async: true

  alias Ecto.Changeset
  alias Tymeslot.Auth.Validation

  describe "validate_login_input/1" do
  @moduletag :auth
    test "returns :ok when email and password are present" do
      params = %{"email" => "test@example.com", "password" => "password123"}
      assert {:ok, ^params} = Validation.validate_login_input(params)
    end

    test "returns :error when email is missing or blank" do
      assert {:error, %{email: ["can't be blank"]}} =
               Validation.validate_login_input(%{"password" => "password123"})

      assert {:error, %{email: ["can't be blank"]}} =
               Validation.validate_login_input(%{"email" => "", "password" => "password123"})
    end

    test "returns :error when password is missing or blank" do
      assert {:error, %{password: ["can't be blank"]}} =
               Validation.validate_login_input(%{"email" => "test@example.com"})

      assert {:error, %{password: ["can't be blank"]}} =
               Validation.validate_login_input(%{"email" => "test@example.com", "password" => ""})
    end

    test "returns :error with multiple errors when both are missing" do
      {:error, errors} = Validation.validate_login_input(%{})
      assert errors.email == ["can't be blank"]
      assert errors.password == ["can't be blank"]
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
      result = Validation.format_validation_errors(errors)
      assert is_map(result) or is_binary(result)
    end

    test "formats {:error, map} errors" do
      errors = {:error, %{email: ["is invalid"]}}
      result = Validation.format_validation_errors(errors)
      assert is_map(result) or is_binary(result)
    end

    test "formats changeset errors" do
      changeset =
        {%{}, %{email: :string}}
        |> Changeset.change(%{email: "invalid"})
        |> Changeset.validate_format(:email, ~r/@/)

      result = Validation.format_validation_errors(changeset)
      assert is_map(result) or is_binary(result)
    end

    test "returns default message for unknown error format" do
      assert Validation.format_validation_errors(nil) == "Invalid input provided."
    end
  end
end
