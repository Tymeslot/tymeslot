defmodule Tymeslot.Security.FieldValidators.NumberValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.NumberValidator

  describe "validate/2" do
    test "integer ok", do: assert(:ok = NumberValidator.validate("42"))
    test "decimal ok", do: assert(:ok = NumberValidator.validate("3.14"))
    test "negative ok", do: assert(:ok = NumberValidator.validate("-1"))
    test "trailing garbage rejected", do: assert({:error, _} = NumberValidator.validate("42x"))

    test "blank required fails",
      do: assert({:error, _} = NumberValidator.validate("", required: true))

    test "blank optional ok", do: assert(:ok = NumberValidator.validate("", required: false))
    test "below min rejected", do: assert({:error, _} = NumberValidator.validate("0", min: 1))
    test "above max rejected", do: assert({:error, _} = NumberValidator.validate("100", max: 50))

    test "nil required fails",
      do: assert({:error, _} = NumberValidator.validate(nil, required: true))

    test "nil optional ok", do: assert(:ok = NumberValidator.validate(nil, required: false))

    test "numeric value within bounds ok" do
      assert :ok = NumberValidator.validate(5, min: 1, max: 10)
    end

    test "non-numeric non-binary value returns error" do
      assert {:error, _} = NumberValidator.validate(:not_a_number)
    end
  end
end
