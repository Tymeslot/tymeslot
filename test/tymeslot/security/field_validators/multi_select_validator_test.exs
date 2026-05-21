defmodule Tymeslot.Security.FieldValidators.MultiSelectValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.MultiSelectValidator

  @field_def %{
    "options" => [
      %{"key" => "a", "label" => "A"},
      %{"key" => "b", "label" => "B"},
      %{"key" => "c", "label" => "C"}
    ]
  }

  describe "validate/3" do
    test "accepts a subset of known keys" do
      assert :ok = MultiSelectValidator.validate(["a", "b"], @field_def)
    end

    test "rejects an unknown key in the list" do
      assert {:error, _msg} = MultiSelectValidator.validate(["a", "z"], @field_def)
    end

    test "rejects non-list" do
      assert {:error, _msg} = MultiSelectValidator.validate("a", @field_def)
    end

    test "empty list required is invalid" do
      assert {:error, _msg} = MultiSelectValidator.validate([], @field_def, required: true)
    end

    test "empty list optional is ok" do
      assert :ok = MultiSelectValidator.validate([], @field_def, required: false)
    end

    test "min_selections enforced" do
      assert {:error, _msg} = MultiSelectValidator.validate(["a"], @field_def, min_selections: 2)
      assert :ok = MultiSelectValidator.validate(["a", "b"], @field_def, min_selections: 2)
    end

    test "max_selections enforced" do
      assert {:error, _msg} =
               MultiSelectValidator.validate(["a", "b", "c"], @field_def, max_selections: 2)

      assert :ok = MultiSelectValidator.validate(["a", "b"], @field_def, max_selections: 2)
    end

    test "rejects non-string elements" do
      assert {:error, _msg} = MultiSelectValidator.validate([1, 2], @field_def)
    end

    test "nil treated as empty required" do
      assert {:error, _msg} = MultiSelectValidator.validate(nil, @field_def, required: true)
    end

    test "nil treated as empty optional" do
      assert :ok = MultiSelectValidator.validate(nil, @field_def, required: false)
    end

    test "accepts all known keys" do
      assert :ok = MultiSelectValidator.validate(["a", "b", "c"], @field_def)
    end

    test "duplicate values do not satisfy min_selections" do
      assert {:error, _msg} =
               MultiSelectValidator.validate(["a", "a"], @field_def, min_selections: 2)
    end
  end
end
