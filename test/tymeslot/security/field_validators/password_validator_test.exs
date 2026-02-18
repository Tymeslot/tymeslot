defmodule Tymeslot.Security.FieldValidators.PasswordValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.PasswordValidator

  describe "validate/2" do
    test "returns :ok for valid passwords" do
      assert :ok = PasswordValidator.validate("StrongPass123!")
      assert :ok = PasswordValidator.validate("Another@456")
      assert :ok = PasswordValidator.validate("P@ssw0rd2026")
    end

    test "returns error for missing special character" do
      assert {:error, "Password must contain at least one special character"} =
               PasswordValidator.validate("StrongPass123")

      assert {:error, "Password must contain at least one special character"} =
               PasswordValidator.validate("NoSpecialChars1")
    end

    test "returns error for missing number" do
      assert {:error, "Password must contain at least one number"} =
               PasswordValidator.validate("StrongPass!")
    end

    test "returns error for missing uppercase" do
      assert {:error, "Password must contain at least one uppercase letter"} =
               PasswordValidator.validate("weakpass123!")
    end

    test "returns error for missing lowercase" do
      assert {:error, "Password must contain at least one lowercase letter"} =
               PasswordValidator.validate("STRONGPASS123!")
    end

    test "returns error for short password" do
      assert {:error, "Password must be at least 8 characters long"} =
               PasswordValidator.validate("Sh0rt!")
    end

    test "returns error for long password" do
      long_password = String.duplicate("a", 81)

      assert {:error, "Password must be at most 80 characters long"} =
               PasswordValidator.validate(long_password)
    end

    test "supports custom min_length and max_length options" do
      assert :ok = PasswordValidator.validate("Sh0rt!", min_length: 5)

      assert {:error, "Password must be at least 15 characters long"} =
               PasswordValidator.validate("Sh0rt!", min_length: 15)

      assert {:error, "Password must be at most 5 characters long"} =
               PasswordValidator.validate("Long1!", max_length: 5, min_length: 1)
    end

    test "returns error for non-binary values" do
      assert {:error, "Password must be a text value"} = PasswordValidator.validate(123)
    end

    test "returns error for empty or nil password" do
      assert {:error, "Password is required"} = PasswordValidator.validate("")
      assert {:error, "Password is required"} = PasswordValidator.validate(nil)
    end
  end

  describe "validate_confirmation/3" do
    test "returns :ok when confirmation matches" do
      assert :ok = PasswordValidator.validate_confirmation("Pass123!", "Pass123!")
    end

    test "returns error when confirmation doesn't match" do
      assert {:error, "Password confirmation does not match"} =
               PasswordValidator.validate_confirmation("Pass123!", "Different123!")
    end

    test "returns error when confirmation is missing" do
      assert {:error, "Password confirmation is required"} =
               PasswordValidator.validate_confirmation("Pass123!", "")

      assert {:error, "Password confirmation is required"} =
               PasswordValidator.validate_confirmation("Pass123!", nil)
    end
  end
end
