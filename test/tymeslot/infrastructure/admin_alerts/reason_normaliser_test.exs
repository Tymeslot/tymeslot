defmodule Tymeslot.Infrastructure.AdminAlerts.ReasonNormaliserTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias Tymeslot.Infrastructure.AdminAlerts.ReasonNormaliser

  describe "normalise/1" do
    test "returns nil when given nil" do
      assert ReasonNormaliser.normalise(nil) == nil
    end

    test "handles bare atoms" do
      assert ReasonNormaliser.normalise(:timeout) == %{
               code: :timeout,
               message: "timeout"
             }
    end

    test "handles binaries" do
      assert ReasonNormaliser.normalise("something went wrong") == %{
               code: nil,
               message: "something went wrong"
             }
    end

    test "handles tagged tuples with binary payload" do
      assert ReasonNormaliser.normalise({:api_error, "invalid_grant"}) == %{
               code: :api_error,
               message: "invalid_grant"
             }
    end

    test "handles tagged tuples with non-binary payload via inspect" do
      assert ReasonNormaliser.normalise({:api_error, {:closed, :econnrefused}}) == %{
               code: :api_error,
               message: "{:closed, :econnrefused}"
             }
    end

    test "handles exception structs" do
      exception = %RuntimeError{message: "boom"}

      assert ReasonNormaliser.normalise(exception) == %{
               code: RuntimeError,
               message: "boom"
             }
    end

    test "handles Ecto.Changeset with traversed errors" do
      import Ecto.Changeset

      types = %{name: :string, age: :integer}

      changeset =
        {%{}, types}
        |> cast(%{}, Map.keys(types))
        |> validate_required([:name, :age])

      assert %{code: :changeset_invalid, message: message} =
               ReasonNormaliser.normalise(changeset)

      assert message =~ "name: can't be blank"
      assert message =~ "age: can't be blank"
    end

    test "falls back to inspect/1 for arbitrary terms" do
      assert ReasonNormaliser.normalise([:a, :b, :c]) == %{
               code: nil,
               message: "[:a, :b, :c]"
             }
    end
  end
end
