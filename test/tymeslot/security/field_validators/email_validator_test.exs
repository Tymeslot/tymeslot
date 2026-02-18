defmodule Tymeslot.Security.FieldValidators.EmailValidatorTest do
  @moduletag :security
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.FieldValidators.EmailValidator

  describe "validate/2" do
  @moduletag :security
    test "returns :ok for valid email addresses" do
      assert :ok = EmailValidator.validate("user@example.com")
      assert :ok = EmailValidator.validate("first.last@domain.co.uk")
      assert :ok = EmailValidator.validate("user+tag@gmail.com")
    end

    test "returns error for nil or empty string" do
      assert {:error, "Email is required"} = EmailValidator.validate(nil)
      assert {:error, "Email is required"} = EmailValidator.validate("")
    end

    test "returns error for long emails" do
      long_email = String.duplicate("a", 244) <> "@example.com"

      assert {:error, "Email exceeds maximum length (254 characters)"} =
               EmailValidator.validate(long_email)
    end

    test "returns error for missing @ symbol" do
      assert {:error, "Email format is invalid (missing @ symbol)"} =
               EmailValidator.validate("userexample.com")
    end

    test "returns error for missing domain" do
      assert {:error, "Email domain is missing"} = EmailValidator.validate("user@")
    end

    test "returns error for missing username" do
      assert {:error, "Email username is missing"} = EmailValidator.validate("@example.com")
    end

    test "returns error for consecutive dots" do
      assert {:error, "Email format is invalid (consecutive dots not allowed)"} =
               EmailValidator.validate("user..name@example.com")
    end

    test "returns error for spaces" do
      assert {:error, "Email format is invalid (spaces not allowed)"} =
               EmailValidator.validate("user name@example.com")
    end

    test "returns error for multiple @ symbols" do
      assert {:error, "Email format is invalid (multiple @ symbols)"} =
               EmailValidator.validate("user@name@example.com")
    end

    test "returns error for invalid domain format" do
      assert {:error, "Email domain format is invalid"} = EmailValidator.validate("user@.com")
      assert {:error, "Email domain format is invalid"} = EmailValidator.validate("user@com.")
      assert {:error, "Email domain format is invalid"} = EmailValidator.validate("user@com")
      assert {:error, "Email domain format is invalid"} = EmailValidator.validate("user@c.")
    end

    test "returns error for general invalid format" do
      # This triggers the consecutive dots check in validate_basic_format
      assert {:error, "Email format is invalid (consecutive dots not allowed)"} =
               EmailValidator.validate("user@domain..com")

      # This should trigger the general regex check (newline is whitespace)
      assert {:error, "Email format is invalid"} = EmailValidator.validate("user@domain\n.com")
    end

    test "returns error for non-binary values" do
      assert {:error, "Email must be a text value"} = EmailValidator.validate(123)
    end
  end
end
