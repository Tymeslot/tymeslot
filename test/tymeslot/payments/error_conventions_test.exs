defmodule Tymeslot.Payments.ErrorConventionsTest do
  @moduletag :payments
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Payments.ErrorConventions

  describe "error_atoms/0" do
  @moduletag :payments
    test "returns a list of atoms" do
      atoms = ErrorConventions.error_atoms()
      assert is_list(atoms)
      assert Enum.all?(atoms, &is_atom/1)
      assert :invalid_amount in atoms
      assert :transaction_not_found in atoms
    end
  end

  describe "standard_error?/1" do
    test "returns true for standard errors" do
      assert ErrorConventions.standard_error?(:invalid_amount)
      assert ErrorConventions.standard_error?(:transaction_not_found)
      assert ErrorConventions.standard_error?(:unauthorized)
    end

    test "returns false for non-standard errors" do
      refute ErrorConventions.standard_error?(:something_else)
      refute ErrorConventions.standard_error?("not an atom")
      refute ErrorConventions.standard_error?(nil)
    end
  end
end
