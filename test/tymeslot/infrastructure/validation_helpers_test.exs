defmodule Tymeslot.Infrastructure.ValidationHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.ValidationHelpers

  describe "validate_required_fields/2" do
    test "returns :ok when all required fields are present" do
      params = %{"email" => "test@example.com", "password" => "secret"}
      required = ["email", "password"]
      assert {:ok, ^params} = ValidationHelpers.validate_required_fields(params, required)
    end

    test "returns errors when required fields are missing" do
      params = %{"email" => "test@example.com"}
      required = ["email", "password"]

      assert {:error, %{password: ["can't be blank"]}} =
               ValidationHelpers.validate_required_fields(params, required)
    end

    test "returns errors when required fields are empty strings" do
      params = %{"email" => "test@example.com", "password" => ""}
      required = ["email", "password"]

      assert {:error, %{password: ["can't be blank"]}} =
               ValidationHelpers.validate_required_fields(params, required)
    end

    test "handles fields that are not existing atoms without crashing" do
      # We now use String.to_existing_atom with a fallback to string
      unique_field = "field_that_definitely_is_not_an_atom_#{:erlang.unique_integer()}"
      params = %{}
      required = [unique_field]

      # Should not raise ArgumentError
      assert {:error, errors} = ValidationHelpers.validate_required_fields(params, required)
      assert Map.has_key?(errors, unique_field)
    end
  end
end
