defmodule Tymeslot.Security.InputProcessorTest do
  @moduletag :security
  use ExUnit.Case, async: true

  alias Tymeslot.Security.InputProcessor

  defmodule AlwaysOkValidator do
    @spec validate(any()) :: :ok
    def validate(_value), do: :ok

    @spec validate(any(), keyword()) :: :ok
    def validate(_value, _opts), do: :ok
  end

  test "validate_form/3 does not create atoms from unexpected string field_specs" do
    field_name = "unexpected_field_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(field_name) end

    assert {:ok, _result} =
             InputProcessor.validate_form(
               %{field_name => "value"},
               [{field_name, AlwaysOkValidator}],
               metadata: %{},
               universal_opts: [log_events: false]
             )

    assert_raise ArgumentError, fn -> String.to_existing_atom(field_name) end
  end

  describe "type-dispatch via atoms" do
    test "resolves :email type to EmailValidator" do
      assert {:ok, _result} =
               InputProcessor.validate_form(
                 %{"email" => "user@example.com"},
                 [{"email", :email}]
               )

      assert {:error, errors} =
               InputProcessor.validate_form(
                 %{"email" => "not-an-email"},
                 [{"email", :email}]
               )

      assert Map.has_key?(errors, :email)
    end

    test "resolves :name type to NameValidator" do
      assert {:ok, _result} =
               InputProcessor.validate_form(
                 %{"name" => "John Smith"},
                 [{"name", :name}]
               )

      assert {:error, errors} =
               InputProcessor.validate_form(
                 %{"name" => ""},
                 [{"name", :name}]
               )

      assert Map.has_key?(errors, :name)
    end

    test "resolves :message type with per-field opts" do
      # With required: false, empty message is allowed
      assert {:ok, _result} =
               InputProcessor.validate_form(
                 %{"message" => ""},
                 [{"message", :message, [required: false, min_length: 0]}]
               )

      # Without opts, empty message is rejected
      assert {:error, errors} =
               InputProcessor.validate_form(
                 %{"message" => ""},
                 [{"message", :message}]
               )

      assert Map.has_key?(errors, :message)
    end

    test "validate_field/2 accepts type atom" do
      assert {:ok, _result} = InputProcessor.validate_field("user@example.com", :email)
      assert {:error, _error} = InputProcessor.validate_field("not-an-email", :email)
    end
  end
end
