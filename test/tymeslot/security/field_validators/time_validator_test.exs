defmodule Tymeslot.Security.FieldValidators.TimeValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.TimeValidator

  describe "validate/2" do
    test "HH:MM ok", do: assert(:ok = TimeValidator.validate("14:30"))
    test "HH:MM:SS ok", do: assert(:ok = TimeValidator.validate("14:30:00"))
    test "invalid format", do: assert({:error, _} = TimeValidator.validate("2pm"))

    test "blank required fails",
      do: assert({:error, _} = TimeValidator.validate("", required: true))

    test "blank optional ok", do: assert(:ok = TimeValidator.validate("", required: false))

    test "nil required fails",
      do: assert({:error, _} = TimeValidator.validate(nil, required: true))

    test "nil optional ok", do: assert(:ok = TimeValidator.validate(nil, required: false))

    test "non-binary value returns error" do
      assert {:error, _} = TimeValidator.validate(1430)
    end
  end
end
