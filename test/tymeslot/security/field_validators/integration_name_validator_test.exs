defmodule Tymeslot.Security.FieldValidators.IntegrationNameValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

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

    test "accepts exactly 100 chars and rejects 101 after trimming padding" do
      exactly_100 = String.duplicate("a", 100)
      assert :ok = IntegrationNameValidator.validate(exactly_100)

      # Leading/trailing whitespace must not shift the max-length check:
      # a 101-char payload stays rejected even when padded with spaces,
      # and a 99-char payload padded to 105 chars is still accepted.
      padded_101 = "   " <> String.duplicate("a", 101) <> "   "

      assert {:error, "Integration name must be 100 characters or less"} =
               IntegrationNameValidator.validate(padded_101)

      padded_99 = "   " <> String.duplicate("a", 99) <> "   "
      assert :ok = IntegrationNameValidator.validate(padded_99)
    end

    test "returns error for non-binary values" do
      assert {:error, "Integration name must be text"} = IntegrationNameValidator.validate(123)

      assert {:error, "Integration name must be text"} =
               IntegrationNameValidator.validate(%{key: "value"})
    end

    test "rejects names composed of zero-width spaces" do
      assert {:error, _reason} = IntegrationNameValidator.validate("\u200B\u200B")
      assert {:error, _reason} = IntegrationNameValidator.validate("\u200B\u200B\u200B")
    end

    test "rejects names composed of BOM or soft hyphen characters" do
      assert {:error, _reason} = IntegrationNameValidator.validate("\uFEFF\uFEFF")
      assert {:error, _reason} = IntegrationNameValidator.validate("\u00AD\u00AD")
    end

    test "accepts valid names that incidentally contain zero-width characters" do
      # "ac" with an embedded zero-width space is still "ac" after stripping — valid.
      assert :ok = IntegrationNameValidator.validate("a\u200Bc")
    end
  end
end
