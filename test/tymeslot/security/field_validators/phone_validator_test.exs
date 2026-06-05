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
      assert {:error, _msg} = PhoneValidator.validate("", required: true)
    end

    test "blank optional is ok" do
      assert :ok = PhoneValidator.validate("", required: false)
    end

    test "letters reject" do
      assert {:error, _msg} = PhoneValidator.validate("call me later")
    end

    test "trim and accept ext / spaces / dashes" do
      assert :ok = PhoneValidator.validate("  +1 (415) 555-0100 ext. 42  ")
    end

    test "rejects an overly long number" do
      assert {:error, msg} = PhoneValidator.validate("+49384894948494949404")
      assert msg =~ "too long"
    end

    test "accepts up to the 17-digit buffer (E.164 + leading 00 prefix)" do
      assert :ok = PhoneValidator.validate("+12345678901234567")
    end

    test "rejects beyond the 17-digit buffer" do
      assert {:error, msg} = PhoneValidator.validate("+123456789012345678")
      assert msg =~ "too long"
    end

    test "the ext segment does not count toward the digit limit" do
      assert :ok = PhoneValidator.validate("+12345678901234567 ext. 9999")
    end

    test "nil required is invalid" do
      assert {:error, _msg} = PhoneValidator.validate(nil, required: true)
    end

    test "nil optional is ok" do
      assert :ok = PhoneValidator.validate(nil, required: false)
    end

    test "non-binary value returns error" do
      assert {:error, _msg} = PhoneValidator.validate(12_345)
    end
  end
end
