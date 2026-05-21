defmodule Tymeslot.Security.FieldValidators.TimeValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.TimeValidator

  describe "validate/2" do
    test "HH:MM ok", do: assert(:ok = TimeValidator.validate("14:30"))
    test "HH:MM:SS ok", do: assert(:ok = TimeValidator.validate("14:30:00"))
    test "invalid format", do: assert({:error, _msg} = TimeValidator.validate("2pm"))

    test "blank required fails",
      do: assert({:error, _msg} = TimeValidator.validate("", required: true))

    test "blank optional ok", do: assert(:ok = TimeValidator.validate("", required: false))

    test "nil required fails",
      do: assert({:error, _msg} = TimeValidator.validate(nil, required: true))

    test "nil optional ok", do: assert(:ok = TimeValidator.validate(nil, required: false))

    test "non-binary value returns error" do
      assert {:error, _msg} = TimeValidator.validate(1430)
    end

    test "rejects timezone offset" do
      assert {:error, _msg} = TimeValidator.validate("14:30:45+01:00")
      assert {:error, _msg} = TimeValidator.validate("14:30:00Z")
      assert {:error, _msg} = TimeValidator.validate("14:30:00-05:00")
    end
  end
end
