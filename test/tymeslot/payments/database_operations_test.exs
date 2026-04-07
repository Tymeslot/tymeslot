defmodule Tymeslot.Payments.DatabaseOperationsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

  alias Tymeslot.Payments.DatabaseOperations
  alias Tymeslot.Payments.PaymentQueries

  import Tymeslot.Factory

  describe "process_subscription_renewal/2" do
    test "treats duplicate renewal as already processed" do
      user = insert(:user)
      subscription_id = "sub_dup"

      insert(:payment_transaction,
        user: user,
        subscription_id: subscription_id,
        status: "completed",
        stripe_id: "sess_base"
      )

      invoice = %{
        "id" => "in_dup",
        "subscription" => subscription_id,
        "amount_paid" => 1000,
        "created" => 1_234_567_890
      }

      assert {:ok, :subscription_processed} =
               DatabaseOperations.process_subscription_renewal(subscription_id, invoice)

      assert {:ok, :already_processed} =
               DatabaseOperations.process_subscription_renewal(subscription_id, invoice)

      assert {:ok, transactions} = PaymentQueries.get_transactions_by_status("completed", user.id)
      assert length(transactions) == 2
    end
  end
end
