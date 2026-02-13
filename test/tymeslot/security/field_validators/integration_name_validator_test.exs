defmodule Tymeslot.Security.FieldValidators.IntegrationNameValidatorTest do
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.FieldValidators.IntegrationNameValidator

  describe "validate/2" do
    test "returns :ok for valid integration names" do
      assert :ok = IntegrationNameValidator.validate("Google Calendar")
      assert :ok = IntegrationNameValidator.validate("MiroTalk")
    end

    test "returns error for nil or empty string" do
      assert {:error, "Integration name is required"} = IntegrationNameValidator.validate(nil)
      assert {:error, "Integration name is required"} = IntegrationNameValidator.validate("")
    end

    test "returns error for short names" do
      assert {:error, "Integration name must be at least 2 characters"} =
               IntegrationNameValidator.validate("A")

      # trimmed check
      assert {:error, "Integration name must be at least 2 characters"} =
               IntegrationNameValidator.validate(" A ")
    end

    test "returns error for long names" do
      long_name = String.duplicate("a", 101)

      assert {:error, "Integration name must be 100 characters or less"} =
               IntegrationNameValidator.validate(long_name)
    end

    test "returns error for non-binary values" do
      assert {:error, "Integration name must be text"} = IntegrationNameValidator.validate(123)

      assert {:error, "Integration name must be text"} =
               IntegrationNameValidator.validate(%{key: "value"})
    end
  end
end
