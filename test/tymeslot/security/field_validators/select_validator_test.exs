defmodule Tymeslot.Security.FieldValidators.SelectValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.SelectValidator

  @field_def %{
    "options" => [%{"key" => "red", "label" => "Red"}, %{"key" => "blue", "label" => "Blue"}]
  }

  describe "validate/3" do
    test "accepts a known option key" do
      assert :ok = SelectValidator.validate("red", @field_def)
    end

    test "rejects unknown option key" do
      assert {:error, _msg} = SelectValidator.validate("green", @field_def)
    end

    test "rejects non-binary" do
      assert {:error, _msg} = SelectValidator.validate(123, @field_def)
    end

    test "blank required is invalid" do
      assert {:error, _msg} = SelectValidator.validate("", @field_def, required: true)
    end

    test "blank optional is ok" do
      assert :ok = SelectValidator.validate("", @field_def, required: false)
    end

    test "nil required is invalid" do
      assert {:error, _msg} = SelectValidator.validate(nil, @field_def, required: true)
    end

    test "nil optional is ok" do
      assert :ok = SelectValidator.validate(nil, @field_def, required: false)
    end

    test "accepts second known option key" do
      assert :ok = SelectValidator.validate("blue", @field_def)
    end

    test "empty options list rejects any value" do
      assert {:error, _msg} = SelectValidator.validate("red", %{"options" => []})
    end
  end
end
