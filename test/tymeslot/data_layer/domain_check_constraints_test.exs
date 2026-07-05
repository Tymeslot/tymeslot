defmodule Tymeslot.DataLayer.DomainCheckConstraintsTest do
  @moduledoc """
  The schemas assume domain invariants (a meeting ends after it starts; money
  amounts are non-negative) that are now enforced by DB check constraints.
  These tests insert structs directly (bypassing the changesets) to prove the
  DB rejects violating rows.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :database

  import Tymeslot.Factory

  describe "meetings_end_after_start" do
    test "rejects a meeting whose end_time is not after its start_time" do
      start = DateTime.utc_now(:second)

      assert_raise Ecto.ConstraintError, ~r/meetings_end_after_start/, fn ->
        insert(:meeting, start_time: DateTime.add(start, 3600, :second), end_time: start)
      end
    end
  end

  describe "payment_transactions non-negative amounts" do
    test "rejects a negative amount" do
      assert_raise Ecto.ConstraintError, ~r/payment_transactions_amount_non_negative/, fn ->
        insert(:payment_transaction, amount: -100)
      end
    end

    test "rejects a negative tax_amount" do
      assert_raise Ecto.ConstraintError, ~r/payment_transactions_tax_amount_non_negative/, fn ->
        insert(:payment_transaction, amount: 100, tax_amount: -1)
      end
    end
  end
end
