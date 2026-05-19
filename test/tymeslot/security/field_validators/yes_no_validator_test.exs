defmodule Tymeslot.Security.FieldValidators.YesNoValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.YesNoValidator

  describe "validate/3" do
    test "true is accepted", do: assert(:ok = YesNoValidator.validate(true, %{}))

    test "false is accepted", do: assert(:ok = YesNoValidator.validate(false, %{}))

    test "true with required: true is ok",
      do: assert(:ok = YesNoValidator.validate(true, %{}, required: true))

    test "false with required: true is ok",
      do: assert(:ok = YesNoValidator.validate(false, %{}, required: true))

    test "nil with required: true fails" do
      assert {:error, _} = YesNoValidator.validate(nil, %{}, required: true)
    end

    test "nil with required: false is ok",
      do: assert(:ok = YesNoValidator.validate(nil, %{}, required: false))

    test "string rejected", do: assert({:error, _} = YesNoValidator.validate("true", %{}))
    test "integer rejected", do: assert({:error, _} = YesNoValidator.validate(1, %{}))

    test "map value rejected" do
      assert {:error, _} = YesNoValidator.validate(%{"value" => true}, %{})
    end
  end
end
