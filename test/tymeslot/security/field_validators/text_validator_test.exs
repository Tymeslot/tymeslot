defmodule Tymeslot.Security.FieldValidators.TextValidatorTest do
  @moduletag :security
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.FieldValidators.TextValidator

  describe "validate/2" do
  @moduletag :security
    test "returns :ok for valid text" do
      assert :ok = TextValidator.validate("Hello world")
      assert :ok = TextValidator.validate("Some short text")
    end

    test "returns error for nil or empty string when required" do
      assert {:error, "Text is required"} = TextValidator.validate(nil)
      assert {:error, "Text is required"} = TextValidator.validate("")
    end

    test "returns :ok for nil or empty string when not required" do
      assert :ok = TextValidator.validate(nil, required: false)
      assert :ok = TextValidator.validate("", required: false)
    end

    test "returns error for blank string (only whitespace) when required" do
      assert {:error, "Text cannot be blank"} = TextValidator.validate("   ")
    end

    test "returns error for short text (when min_length > 0)" do
      # Default min_length is 1, so empty string after trim would be blank
      assert {:error, "Text cannot be blank"} = TextValidator.validate(" ")

      assert {:error, "Text is too short (minimum 5 characters)"} =
               TextValidator.validate("ABC", min_length: 5)
    end

    test "returns error for long text" do
      long_text = String.duplicate("a", 501)

      assert {:error, "Text is too long (maximum 500 characters)"} =
               TextValidator.validate(long_text)
    end

    test "supports custom min_length and max_length options" do
      assert :ok = TextValidator.validate("A", min_length: 1)

      assert {:error, "Text is too short (minimum 10 characters)"} =
               TextValidator.validate("Short", min_length: 10)

      assert {:error, "Text is too long (maximum 5 characters)"} =
               TextValidator.validate("Too long", max_length: 5)
    end

    test "returns error for non-binary values" do
      assert {:error, "Text must be a text value"} = TextValidator.validate(123)
      assert {:error, "Text must be a text value"} = TextValidator.validate(%{key: "value"})
    end
  end

  describe "get_config/2" do
    test "returns default values" do
      assert TextValidator.get_config(:min_length) == 1
      assert TextValidator.get_config(:max_length) == 500
    end

    test "returns values from options" do
      assert TextValidator.get_config(:min_length, min_length: 10) == 10
      assert TextValidator.get_config(:max_length, max_length: 1000) == 1000
    end

    test "returns nil for unknown keys" do
      assert TextValidator.get_config(:unknown) == nil
    end
  end
end
