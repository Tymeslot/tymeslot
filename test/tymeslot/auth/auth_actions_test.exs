defmodule Tymeslot.Auth.AuthActionsTest do
  @moduledoc """
  Tests for AuthActions module - focusing on pure functions and validation logic.
  """

  use Tymeslot.DataCase, async: true

  alias Tymeslot.Auth.AuthActions

  describe "convert_terms_accepted/1" do
    test "converts string 'true' to boolean true" do
      params = %{"terms_accepted" => "true", "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == true
    end

    test "keeps boolean true as true" do
      params = %{"terms_accepted" => true, "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == true
    end

    test "converts string 'false' to boolean false" do
      params = %{"terms_accepted" => "false", "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == false
    end

    test "converts nil to false" do
      params = %{"terms_accepted" => nil, "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == false
    end

    test "converts any other value to false" do
      params = %{"terms_accepted" => "yes", "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == false
    end

    test "defaults to false when key is missing" do
      params = %{"email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == false
    end

    test "preserves other keys" do
      params = %{
        "terms_accepted" => "true",
        "email" => "test@test.com",
        "name" => "Test User"
      }

      result = AuthActions.convert_terms_accepted(params)
      assert result["email"] == "test@test.com"
      assert result["name"] == "Test User"
    end
  end

  describe "convert_profile_params/1" do
    test "converts string keys to atom keys" do
      params = %{
        "full_name" => "Test User",
        "timezone" => "America/New_York"
      }

      assert {:ok, result} = AuthActions.convert_profile_params(params)
      assert result.full_name == "Test User"
      assert result.timezone == "America/New_York"
    end

    test "handles empty map" do
      assert {:ok, result} = AuthActions.convert_profile_params(%{})
      assert result == %{}
    end

    test "handles nested values" do
      params = %{
        "full_name" => "Test User",
        "settings" => %{"theme" => "dark"}
      }

      assert {:ok, result} = AuthActions.convert_profile_params(params)
      assert result.full_name == "Test User"
      # Nested maps may or may not be converted - depends on implementation
    end
  end

  describe "validate_signup_input/1" do
    test "returns sanitized data for valid signup input" do
      params = %{
        "email" => " Test@Example.com ",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "full_name" => " Test User ",
        "terms_accepted" => "true"
      }

      assert {:ok, valid} = AuthActions.validate_signup_input(params)
      assert valid["email"] == "test@example.com"
      assert valid["full_name"] == "Test User"
    end

    test "returns error when email format is invalid" do
      params = %{
        "email" => "not-an-email",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "full_name" => "Test User",
        "terms_accepted" => "true"
      }

      assert {:error, %{email: ["has invalid format"]}} =
               AuthActions.validate_signup_input(params)
    end

    test "returns error when terms are not accepted" do
      params = %{
        "email" => "test@example.com",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "full_name" => "Test User",
        "terms_accepted" => "false"
      }

      assert {:error, %{terms_accepted: ["must be accepted"]}} =
               AuthActions.validate_signup_input(params)
    end
  end

  describe "validate_login_input/1" do
    test "sanitizes email and passes through valid login input" do
      params = %{"email" => " TEST@example.com ", "password" => "SomePassword123!"}

      assert {:ok, valid} = AuthActions.validate_login_input(params)
      assert valid["email"] == "test@example.com"
    end

    test "returns error for blank password" do
      params = %{"email" => "test@example.com", "password" => ""}

      assert {:error, %{password: ["can't be blank"]}} =
               AuthActions.validate_login_input(params)
    end

    test "returns error for missing fields" do
      assert {:error, %{base: ["Invalid input format"]}} =
               AuthActions.validate_login_input(%{"email" => "test@example.com"})
    end
  end

  describe "validate_password_reset_input/1" do
    test "accepts valid password reset input" do
      params = %{
        "password" => "NewValidPassword123!",
        "password_confirmation" => "NewValidPassword123!"
      }

      assert {:ok, _} = AuthActions.validate_password_reset_input(params)
    end

    test "returns error for password mismatch" do
      params = %{
        "password" => "NewValidPassword123!",
        "password_confirmation" => "DifferentPassword123!"
      }

      assert {:error, %{password_confirmation: ["does not match password"]}} =
               AuthActions.validate_password_reset_input(params)
    end

    test "returns error for weak password" do
      params = %{
        "password" => "weak",
        "password_confirmation" => "weak"
      }

      assert {:error, %{password: ["should be at least 8 character(s)"]}} =
               AuthActions.validate_password_reset_input(params)
    end
  end

  describe "validate_complete_registration/2" do
    test "accepts valid complete registration" do
      auth_params = %{
        "email" => "test@example.com",
        "terms_accepted" => "true"
      }

      profile_params = %{
        "full_name" => "Test User"
      }

      assert {:ok, valid} = AuthActions.validate_complete_registration(auth_params, profile_params)
      assert valid["email"] == "test@example.com"
      assert valid["full_name"] == "Test User"
    end

    test "returns error for invalid email" do
      auth_params = %{
        "email" => "not-an-email",
        "terms_accepted" => "true"
      }

      profile_params = %{
        "full_name" => "Test User"
      }

      assert {:error, %{email: ["has invalid format"]}} =
               AuthActions.validate_complete_registration(auth_params, profile_params)
    end

    test "allows missing full_name" do
      auth_params = %{
        "email" => "test@example.com",
        "terms_accepted" => "true"
      }

      profile_params = %{"full_name" => ""}

      assert {:ok, valid} = AuthActions.validate_complete_registration(auth_params, profile_params)
      assert valid["full_name"] in [nil, ""]
    end
  end
end
