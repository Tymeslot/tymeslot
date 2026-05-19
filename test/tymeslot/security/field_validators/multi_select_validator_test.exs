defmodule Tymeslot.Security.FieldValidators.MultiSelectValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.MultiSelectValidator

  @def %{
    "options" => [
      %{"key" => "a", "label" => "A"},
      %{"key" => "b", "label" => "B"},
      %{"key" => "c", "label" => "C"}
    ]
  }

  describe "validate/3" do
    test "accepts a subset of known keys" do
      assert :ok = MultiSelectValidator.validate(["a", "b"], @def)
    end

    test "rejects an unknown key in the list" do
      assert {:error, _msg} = MultiSelectValidator.validate(["a", "z"], @def)
    end

    test "rejects non-list" do
      assert {:error, _msg} = MultiSelectValidator.validate("a", @def)
    end

    test "empty list required is invalid" do
      assert {:error, _msg} = MultiSelectValidator.validate([], @def, required: true)
    end

    test "empty list optional is ok" do
      assert :ok = MultiSelectValidator.validate([], @def, required: false)
    end

    test "min_selections enforced" do
      assert {:error, _msg} = MultiSelectValidator.validate(["a"], @def, min_selections: 2)
      assert :ok = MultiSelectValidator.validate(["a", "b"], @def, min_selections: 2)
    end

    test "max_selections enforced" do
      assert {:error, _msg} = MultiSelectValidator.validate(["a", "b", "c"], @def, max_selections: 2)
      assert :ok = MultiSelectValidator.validate(["a", "b"], @def, max_selections: 2)
    end

    test "rejects non-string elements" do
      assert {:error, _msg} = MultiSelectValidator.validate([1, 2], @def)
    end

    test "nil treated as empty required" do
      assert {:error, _msg} = MultiSelectValidator.validate(nil, @def, required: true)
    end

    test "nil treated as empty optional" do
      assert :ok = MultiSelectValidator.validate(nil, @def, required: false)
    end

    test "accepts all known keys" do
      assert :ok = MultiSelectValidator.validate(["a", "b", "c"], @def)
    end

    test "duplicate values do not satisfy min_selections" do
      assert {:error, _msg} = MultiSelectValidator.validate(["a", "a"], @def, min_selections: 2)
    end
  end
end
