defmodule Tymeslot.Security.FieldValidators.MessageValidatorTest do
  @moduletag :security
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.FieldValidators.MessageValidator

  describe "validate/2" do
  @moduletag :security
    test "returns :ok for valid messages" do
      assert :ok =
               MessageValidator.validate(
                 "This is a valid message that meets the length requirements."
               )

      assert :ok = MessageValidator.validate("Another valid message with enough content.")
    end

    test "returns error for nil or empty string when required" do
      assert {:error, "Message is required"} = MessageValidator.validate(nil)
      assert {:error, "Message is required"} = MessageValidator.validate("")
    end

    test "returns :ok for nil or empty string when not required" do
      assert :ok = MessageValidator.validate(nil, required: false)
      assert :ok = MessageValidator.validate("", required: false)
    end

    test "returns error for blank string (only whitespace) when required" do
      assert {:error, "Message cannot be blank"} = MessageValidator.validate("   ")
    end

    test "returns error for short messages" do
      assert {:error, "Message is too short (minimum 10 characters)"} =
               MessageValidator.validate("Too short")
    end

    test "returns error for long messages" do
      long_message = String.duplicate("a", 2001)

      assert {:error, "Message is too long (maximum 2000 characters)"} =
               MessageValidator.validate(long_message)
    end

    test "returns error for meaningless content" do
      assert {:error, "Message must contain meaningful content"} =
               MessageValidator.validate("!!! ??? ...")

      assert {:error, "Message must contain meaningful content"} =
               MessageValidator.validate("ab !!! ??? ...")
    end

    test "supports custom min_length option" do
      assert :ok = MessageValidator.validate("Short", min_length: 5)

      assert {:error, "Message is too short (minimum 15 characters)"} =
               MessageValidator.validate("Too short", min_length: 15)
    end

    test "supports custom max_length option" do
      assert :ok = MessageValidator.validate("Valid message", max_length: 20)

      assert {:error, "Message is too long (maximum 5 characters)"} =
               MessageValidator.validate("Too long", max_length: 5, min_length: 1)
    end

    test "returns error for non-binary values" do
      assert {:error, "Message must be a text value"} = MessageValidator.validate(123)
      assert {:error, "Message must be a text value"} = MessageValidator.validate(%{key: "value"})
    end
  end
end
