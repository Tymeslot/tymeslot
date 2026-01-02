defmodule Tymeslot.Security.InputProcessorTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Security.InputProcessor

  defmodule AlwaysOkValidator do
    @spec validate(any()) :: :ok
    def validate(_value), do: :ok
  end

  test "validate_form/3 does not create atoms from unexpected string field_specs" do
    field_name = "unexpected_field_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(field_name) end

    assert {:ok, _} =
             InputProcessor.validate_form(
               %{field_name => "value"},
               [{field_name, AlwaysOkValidator}],
               metadata: %{},
               universal_opts: [log_events: false]
             )

    assert_raise ArgumentError, fn -> String.to_existing_atom(field_name) end
  end
end
