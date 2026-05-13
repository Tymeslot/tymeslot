defmodule Tymeslot.Security.FieldValidators.YesNoValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.YesNoValidator

  describe "validate/3" do
    test "true accepted always", do: assert(:ok = YesNoValidator.validate(true, %{}))

    test "false required fails",
      do: assert({:error, _} = YesNoValidator.validate(false, %{}, required: true))

    test "false optional ok",
      do: assert(:ok = YesNoValidator.validate(false, %{}, required: false))

    test "nil treated as false (required fails)" do
      assert {:error, _} = YesNoValidator.validate(nil, %{}, required: true)
    end

    test "nil optional ok", do: assert(:ok = YesNoValidator.validate(nil, %{}, required: false))
    test "string rejected", do: assert({:error, _} = YesNoValidator.validate("true", %{}))
    test "integer rejected", do: assert({:error, _} = YesNoValidator.validate(1, %{}))

    test "true with required: true is ok" do
      assert :ok = YesNoValidator.validate(true, %{}, required: true)
    end

    test "map value rejected" do
      assert {:error, _} = YesNoValidator.validate(%{"value" => true}, %{})
    end
  end
end
