defmodule Tymeslot.Security.FieldValidators.FullNameValidatorTest do
  @moduletag :security
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.FieldValidators.FullNameValidator

  describe "validate/2" do
  @moduletag :security
    test "returns :ok for valid full names" do
      assert :ok = FullNameValidator.validate("John Smith")
      assert :ok = FullNameValidator.validate("José María")
      assert :ok = FullNameValidator.validate("O'Connor")
      assert :ok = FullNameValidator.validate("Anne-Marie")
    end

    test "returns :ok for nil or empty string (optional field)" do
      assert :ok = FullNameValidator.validate(nil)
      assert :ok = FullNameValidator.validate("")
      assert :ok = FullNameValidator.validate("   ")
    end

    test "returns error for long names" do
      long_name = String.duplicate("a", 101)

      assert {:error, "Full name is too long (maximum 100 characters)"} =
               FullNameValidator.validate(long_name)
    end

    test "returns error for invalid characters" do
      assert {:error, "Full name contains invalid characters"} =
               FullNameValidator.validate("John<script>")

      assert {:error, "Full name contains invalid characters"} =
               FullNameValidator.validate("Name;")
    end

    test "returns error for only numbers" do
      assert {:error, "Full name cannot be only numbers"} = FullNameValidator.validate("12345")
      assert {:error, "Full name cannot be only numbers"} = FullNameValidator.validate("123 45")
    end

    test "returns error for excessive whitespace" do
      assert {:error, "Full name contains excessive whitespace"} =
               FullNameValidator.validate("John   Smith")
    end

    test "supports custom max_length option" do
      assert {:error, "Full name is too long (maximum 5 characters)"} =
               FullNameValidator.validate("Too long", max_length: 5)
    end

    test "returns error for non-binary values" do
      assert {:error, "Full name must be a text value"} = FullNameValidator.validate(123)

      assert {:error, "Full name must be a text value"} =
               FullNameValidator.validate(%{key: "value"})
    end
  end
end
