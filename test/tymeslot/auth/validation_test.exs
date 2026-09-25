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

  describe "terms_accepted?/1" do
    test "a checked box, and true, count as acceptance" do
      for value <- ["on", "true", true], do: assert(Validation.terms_accepted?(value))
    end

    test "anything else does not" do
      for value <- [nil, "", "false", false, "yes", 1],
          do: refute(Validation.terms_accepted?(value))
    end
  end

  describe "validate_login_input/2" do
    test "accepts a well-formed email and a present password" do
      assert :ok = Validation.validate_login_input("user@example.com", "anything")
    end

    test "reports each field's problem at once, translated" do
      assert {:error, %{email: email_error, password: "Password is required"}} =
               Validation.validate_login_input("not-an-email", "")

      assert byte_size(email_error) > 0
    end

    test "refuses a password longer than login hashes" do
      assert {:error, %{password: "Password is too long"}} =
               Validation.validate_login_input("user@example.com", String.duplicate("a", 1025))
    end

    test "treats a missing password as required" do
      assert {:error, %{password: "Password is required"}} =
               Validation.validate_login_input("user@example.com", nil)
    end
  end
end
