defmodule Tymeslot.Auth.ValidationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Tymeslot.Auth.Validation

  describe "validate_new_password_input/1" do
    test "rejects a password that fails the strength rules" do
      params = %{"password" => "short"}
      assert {:error, _reason} = Validation.validate_new_password_input(params)
    end
  end
end
