defmodule Tymeslot.Security.FieldValidators.NameValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.NameValidator

  describe "validate/2" do
    test "returns :ok for valid names" do
      assert :ok = NameValidator.validate("John Smith")
      assert :ok = NameValidator.validate("José María")
      assert :ok = NameValidator.validate("O'Connor")
      assert :ok = NameValidator.validate("Anne-Marie")
    end

    test "returns error for nil or empty string" do
      assert {:error, "Name is required"} = NameValidator.validate(nil)
      assert {:error, "Name is required"} = NameValidator.validate("")
    end

    test "returns error for blank string (only whitespace)" do
      assert {:error, "Name cannot be blank"} = NameValidator.validate("   ")
    end

    test "returns error for short names" do
      assert {:error, "Name is too short (minimum 2 characters)"} = NameValidator.validate("A")
    end

    test "returns error for long names" do
      long_name = String.duplicate("a", 101)

      assert {:error, "Name is too long (maximum 100 characters)"} =
               NameValidator.validate(long_name)
    end

    test "returns error for invalid characters" do
      assert {:error, "Name contains invalid characters"} = NameValidator.validate("John<script>")
      assert {:error, "Name contains invalid characters"} = NameValidator.validate("Name;")
      assert {:error, "Name contains invalid characters"} = NameValidator.validate("Name\\")
    end

    test "returns error for only numbers" do
      assert {:error, "Name cannot be only numbers"} = NameValidator.validate("12345")
      assert {:error, "Name cannot be only numbers"} = NameValidator.validate("123 45")
    end

    test "returns error for excessive whitespace" do
      assert {:error, "Name contains excessive whitespace"} =
               NameValidator.validate("John   Smith")
    end

    test "supports custom min_length and max_length options" do
      assert :ok = NameValidator.validate("A", min_length: 1)

      assert {:error, "Name is too short (minimum 5 characters)"} =
               NameValidator.validate("John", min_length: 5)

      assert {:error, "Name is too long (maximum 5 characters)"} =
               NameValidator.validate("Too long", max_length: 5)
    end

    test "returns error for non-binary values" do
      assert {:error, "Name must be a text value"} = NameValidator.validate(123)
      assert {:error, "Name must be a text value"} = NameValidator.validate(%{key: "value"})
    end
  end
end
