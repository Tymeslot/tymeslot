defmodule Tymeslot.Security.FieldValidators.NumberValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.NumberValidator

  describe "validate/2" do
    test "integer ok", do: assert(:ok = NumberValidator.validate("42"))
    test "decimal ok", do: assert(:ok = NumberValidator.validate("3.14"))
    test "negative ok", do: assert(:ok = NumberValidator.validate("-1"))
    test "trailing garbage rejected", do: assert({:error, _msg} = NumberValidator.validate("42x"))

    test "blank required fails",
      do: assert({:error, _msg} = NumberValidator.validate("", required: true))

    test "blank optional ok", do: assert(:ok = NumberValidator.validate("", required: false))
    test "below min rejected", do: assert({:error, _msg} = NumberValidator.validate("0", min: 1))

    test "above max rejected",
      do: assert({:error, _msg} = NumberValidator.validate("100", max: 50))

    test "nil required fails",
      do: assert({:error, _msg} = NumberValidator.validate(nil, required: true))

    test "nil optional ok", do: assert(:ok = NumberValidator.validate(nil, required: false))

    test "numeric value within bounds ok" do
      assert :ok = NumberValidator.validate(5, min: 1, max: 10)
    end

    test "string bounds are parsed (host stores min/max as strings)" do
      assert :ok = NumberValidator.validate("5", min: "1", max: "10")
      assert {:error, _msg} = NumberValidator.validate("0", min: "1")
      assert {:error, _msg} = NumberValidator.validate("100", max: "50")
    end

    test "unparseable string bound is ignored rather than crashing" do
      assert :ok = NumberValidator.validate("5", min: "not-a-number")
    end

    test "non-numeric non-binary value returns error" do
      assert {:error, _msg} = NumberValidator.validate(:not_a_number)
    end

    test "308-digit integer does not crash and is accepted" do
      value = String.duplicate("9", 308)
      assert :ok = NumberValidator.validate(value)
    end

    test "309-digit integer does not crash (Float.parse would overflow)" do
      # The bug: Float.parse/1 raises ArgumentError on >=309 significant
      # digits, killing the booking LiveView. We must return a result, never
      # raise. A pure-integer string parses via the Integer fallback.
      value = String.duplicate("9", 309)
      assert :ok = NumberValidator.validate(value)
    end

    test "absurdly long input is rejected, not parsed" do
      value = String.duplicate("9", 5_000)
      assert {:error, _msg} = NumberValidator.validate(value)
    end

    test "huge decimal with 309-digit mantissa does not crash" do
      value = String.duplicate("9", 309) <> ".5"
      assert {:error, _msg} = NumberValidator.validate(value)
    end

    test "exponent overflow form \"1e400\" returns error instead of raising" do
      assert {:error, _msg} = NumberValidator.validate("1e400")
    end

    test "negative exponent overflow \"-1e400\" returns error instead of raising" do
      assert {:error, _msg} = NumberValidator.validate("-1e400")
    end
  end
end
