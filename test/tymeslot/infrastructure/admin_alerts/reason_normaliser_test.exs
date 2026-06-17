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

    test "truncates long binary reason to 500 characters with ellipsis" do
      long_message = String.duplicate("x", 600)
      %{code: nil, message: result} = ReasonNormaliser.normalise(long_message)
      assert String.length(result) == 501
      assert String.ends_with?(result, "…")
      assert String.starts_with?(result, String.duplicate("x", 500))
    end

    test "does not truncate reason messages at or below 500 characters" do
      exact_500 = String.duplicate("y", 500)
      assert %{code: nil, message: ^exact_500} = ReasonNormaliser.normalise(exact_500)
    end

    test "truncates long exception messages to 500 characters with ellipsis" do
      long_exception = %RuntimeError{message: String.duplicate("e", 600)}
      %{code: RuntimeError, message: result} = ReasonNormaliser.normalise(long_exception)
      assert String.length(result) == 501
      assert String.ends_with?(result, "…")
    end

    test "truncates long tagged-tuple detail inspections to 500 characters with ellipsis" do
      big_map = Map.new(1..200, fn i -> {i, String.duplicate("v", 10)} end)
      %{code: :db_error, message: result} = ReasonNormaliser.normalise({:db_error, big_map})
      assert String.length(result) <= 501
    end

    test "truncates arbitrary large terms to 500 characters with ellipsis" do
      big_list = Enum.to_list(1..10_000)
      %{code: nil, message: result} = ReasonNormaliser.normalise(big_list)
      assert String.length(result) <= 501
    end
  end
end
