defmodule Tymeslot.Security.FieldValidators.SelectValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.SelectValidator

  @def %{
    "options" => [%{"key" => "red", "label" => "Red"}, %{"key" => "blue", "label" => "Blue"}]
  }

  describe "validate/3" do
    test "accepts a known option key" do
      assert :ok = SelectValidator.validate("red", @def)
    end

    test "rejects unknown option key" do
      assert {:error, _} = SelectValidator.validate("green", @def)
    end

    test "rejects non-binary" do
      assert {:error, _} = SelectValidator.validate(123, @def)
    end

    test "blank required is invalid" do
      assert {:error, _} = SelectValidator.validate("", @def, required: true)
    end

    test "blank optional is ok" do
      assert :ok = SelectValidator.validate("", @def, required: false)
    end

    test "nil required is invalid" do
      assert {:error, _} = SelectValidator.validate(nil, @def, required: true)
    end

    test "nil optional is ok" do
      assert :ok = SelectValidator.validate(nil, @def, required: false)
    end

    test "accepts second known option key" do
      assert :ok = SelectValidator.validate("blue", @def)
    end

    test "empty options list rejects any value" do
      assert {:error, _} = SelectValidator.validate("red", %{"options" => []})
    end
  end
end
