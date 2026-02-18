defmodule Tymeslot.Security.FieldValidators.UsernameValidatorTest do
  use ExUnit.Case, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.UsernameValidator

  describe "validate/2" do
    test "accepts valid usernames" do
      assert :ok = UsernameValidator.validate("john_doe")
      assert :ok = UsernameValidator.validate("jane-doe")
      assert :ok = UsernameValidator.validate("user123")
      assert :ok = UsernameValidator.validate("a1-b2_c3")
    end

    test "rejects nil or empty username" do
      assert {:error, "Username is required"} = UsernameValidator.validate(nil)
      assert {:error, "Username is required"} = UsernameValidator.validate("")
      # "   " is trimmed to "" and then fails length check (min 3)
      assert {:error, "Username must be at least 3 characters long"} =
               UsernameValidator.validate("   ")
    end

    test "rejects non-string values" do
      assert {:error, "Username must be a text value"} = UsernameValidator.validate(123)
      assert {:error, "Username must be a text value"} = UsernameValidator.validate(%{})
    end

    test "rejects usernames that are too short" do
      assert {:error, "Username must be at least 3 characters long"} =
               UsernameValidator.validate("ab")

      assert {:error, "Username must be at least 3 characters long"} =
               UsernameValidator.validate("a")
    end

    test "rejects usernames that are too long" do
      long_username = String.duplicate("a", 31)

      assert {:error, "Username must be at most 30 characters long"} =
               UsernameValidator.validate(long_username)
    end

    test "rejects invalid characters" do
      error_msg =
        "Username must start with a letter or number and contain only lowercase letters, numbers, underscores, and hyphens"

      # uppercase
      assert {:error, ^error_msg} = UsernameValidator.validate("JohnDoe")
      # space
      assert {:error, ^error_msg} = UsernameValidator.validate("john doe")
      # special char
      assert {:error, ^error_msg} = UsernameValidator.validate("john@doe")
      # starts with underscore
      assert {:error, ^error_msg} = UsernameValidator.validate("_johndoe")
      # starts with hyphen
      assert {:error, ^error_msg} = UsernameValidator.validate("-johndoe")
    end

    test "rejects reserved words" do
      reserved_words = ["admin", "api", "login", "root", "test"]

      for word <- reserved_words do
        assert {:error, "This username is reserved and cannot be used"} =
                 UsernameValidator.validate(word)
      end
    end

    test "allows custom min/max length via options" do
      assert :ok = UsernameValidator.validate("ab", min_length: 2)

      assert {:error, "Username must be at most 5 characters long"} =
               UsernameValidator.validate("toolong", max_length: 5)
    end
  end
end
