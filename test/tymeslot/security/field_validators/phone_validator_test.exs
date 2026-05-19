defmodule Tymeslot.Security.FieldValidators.PhoneValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.PhoneValidator

  describe "validate/2" do
    test "valid international phone passes" do
      assert :ok = PhoneValidator.validate("+44 20 7946 0958")
    end

    test "valid local phone passes when an obvious phone shape" do
      assert :ok = PhoneValidator.validate("020 7946 0958")
    end

    test "blank required is invalid" do
      assert {:error, _} = PhoneValidator.validate("", required: true)
    end

    test "blank optional is ok" do
      assert :ok = PhoneValidator.validate("", required: false)
    end

    test "letters reject" do
      assert {:error, _} = PhoneValidator.validate("call me later")
    end

    test "trim and accept ext / spaces / dashes" do
      assert :ok = PhoneValidator.validate("  +1 (415) 555-0100 ext. 42  ")
    end

    test "nil required is invalid" do
      assert {:error, _} = PhoneValidator.validate(nil, required: true)
    end

    test "nil optional is ok" do
      assert :ok = PhoneValidator.validate(nil, required: false)
    end

    test "non-binary value returns error" do
      assert {:error, _} = PhoneValidator.validate(12_345)
    end
  end
end
