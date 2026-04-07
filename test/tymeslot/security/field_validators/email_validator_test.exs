defmodule Tymeslot.Security.FieldValidators.EmailValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.EmailValidator

  describe "validate/2" do
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

  describe "validate/2 TLD validation" do
    test "accepts emails with valid TLDs" do
      assert :ok = EmailValidator.validate("user@example.com")
      assert :ok = EmailValidator.validate("user@example.org")
      assert :ok = EmailValidator.validate("user@example.co.uk")
      assert :ok = EmailValidator.validate("user@example.de")
      assert :ok = EmailValidator.validate("user@example.io")
    end

    test "rejects emails with invalid TLDs and shows the ending" do
      {:error, msg} = EmailValidator.validate("user@example.or")
      assert msg =~ "unrecognised domain ending"
      assert msg =~ ".or"
    end

    test "includes suggestion when confident" do
      {:error, msg} = EmailValidator.validate("user@example.ocm")
      assert msg =~ "unrecognised domain ending"
      assert msg =~ ".ocm"
      assert msg =~ "did you mean .com?"
    end

    test "omits suggestion when ambiguous" do
      {:error, msg} = EmailValidator.validate("user@example.or")
      refute msg =~ "did you mean"
    end

    test "handles case-insensitive TLDs" do
      assert :ok = EmailValidator.validate("user@example.COM")
      assert :ok = EmailValidator.validate("user@example.Co.Uk")
    end

    test "extracts multi-part TLD correctly" do
      assert :ok = EmailValidator.validate("user@company.co.uk")
      assert :ok = EmailValidator.validate("user@uni.ac.jp")
    end
  end
end
