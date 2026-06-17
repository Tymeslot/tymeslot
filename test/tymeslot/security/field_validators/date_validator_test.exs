defmodule Tymeslot.Security.FieldValidators.DateValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.DateValidator

  describe "validate/2" do
    test "ISO-8601 date ok", do: assert(:ok = DateValidator.validate("2026-05-13"))
    test "invalid format", do: assert({:error, _msg} = DateValidator.validate("13/05/2026"))

    test "blank required fails",
      do: assert({:error, _msg} = DateValidator.validate("", required: true))

    test "blank optional ok", do: assert(:ok = DateValidator.validate("", required: false))

    test "below min rejected" do
      assert {:error, _msg} = DateValidator.validate("2020-01-01", min: "2026-01-01")
    end

    test "above max rejected" do
      assert {:error, _msg} = DateValidator.validate("2030-01-01", max: "2026-12-31")
    end

    test "within range ok" do
      assert :ok = DateValidator.validate("2026-06-01", min: "2026-01-01", max: "2026-12-31")
    end

    test "nil required fails",
      do: assert({:error, _msg} = DateValidator.validate(nil, required: true))

    test "nil optional ok", do: assert(:ok = DateValidator.validate(nil, required: false))

    test "non-binary value returns error" do
      assert {:error, _msg} = DateValidator.validate(20_260_513)
    end

    test "returns error tuple on invalid min bound config" do
      assert {:error, _msg} = DateValidator.validate("2026-05-13", min: "not-a-date")
    end

    test "returns error tuple on invalid max bound config" do
      assert {:error, _msg} = DateValidator.validate("2026-05-13", max: "13/05/2026")
    end

    test "legacy integer bound is treated as no bound (does not crash)" do
      # Before date bounds were stored as ISO strings the field stored an
      # integer min/max. A leftover integer must not raise FunctionClauseError.
      assert :ok = DateValidator.validate("2026-05-13", min: 5)
      assert :ok = DateValidator.validate("2026-05-13", max: 5)
    end
  end
end
