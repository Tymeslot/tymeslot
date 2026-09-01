defmodule Tymeslot.Payments.DatabaseOperationsSideEffectsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments

  import Tymeslot.Factory

  alias Tymeslot.Payments.DatabaseOperations
  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Repo

  describe "process_subscription_failure/2" do
    test "moves the transaction to pending_reconciliation and stores invoice metadata" do
      user = insert(:user)
      subscription_id = "sub_failing_1"

      tx =
        insert(:payment_transaction,
          user: user,
          status: "completed",
          subscription_id: subscription_id,
          stripe_id: "cs_fail_base_1",
          metadata: %{"original" => "preserved"}
        )

      invoice = %{
        "id" => "in_failed_1",
        "subscription" => subscription_id,
        "created" => 1_700_000_000,
        "billing_reason" => "subscription_cycle",
        "attempt_count" => 2
      }

      assert {:ok, :failure_processed} =
               DatabaseOperations.process_subscription_failure(subscription_id, invoice)

      reloaded = Repo.reload(tx)
      assert reloaded.status == "pending_reconciliation"
      assert reloaded.metadata["original"] == "preserved"
      assert reloaded.metadata["failed_invoice_id"] == "in_failed_1"
      assert reloaded.metadata["failure_reason"] == "subscription_cycle"
      assert reloaded.metadata["payment_attempt_count"] == 2
    end

    test "returns :subscription_not_found when no matching active subscription exists" do
      invoice = %{"id" => "in_orphan", "subscription" => "sub_orphan", "created" => 0}

      assert {:error, :subscription_not_found} =
               DatabaseOperations.process_subscription_failure("sub_orphan", invoice)
    end
  end

  describe "update_transaction_for_subscription/4" do
    test "links the checkout session to a subscription_id" do
      user = insert(:user)
      checkout_session_id = "cs_link_1"
      subscription_id = "sub_link_1"

      insert(:payment_transaction,
        user: user,
        status: "pending",
        stripe_id: checkout_session_id,
        metadata: %{"checkout_session" => checkout_session_id}
      )

      assert {:ok, updated} =
               DatabaseOperations.update_transaction_for_subscription(
                 checkout_session_id,
                 subscription_id,
                 "completed",
                 %{"plan" => "pro"}
               )

      assert updated.subscription_id == subscription_id
      assert updated.status == "completed"
      assert updated.metadata["plan"] == "pro"
      assert updated.metadata["checkout_session"] == checkout_session_id
    end

    test "returns :transaction_not_found when the checkout session has no matching transaction" do
      assert {:error, :transaction_not_found} =
               DatabaseOperations.update_transaction_for_subscription(
                 "cs_missing",
                 "sub_x",
                 "completed",
                 %{}
               )
    end
  end

  describe "process_failed_payment/1" do
    test "marks the transaction failed when the stripe_id matches" do
      user = insert(:user)

      tx =
        insert(:payment_transaction,
          user: user,
          status: "pending",
          stripe_id: "cs_to_fail"
        )

      assert {:ok, :payment_failed} = DatabaseOperations.process_failed_payment("cs_to_fail")

      assert PaymentQueries.get_transaction_by_stripe_id(tx.stripe_id)
             |> elem(1)
             |> Map.fetch!(:status) == "failed"
    end

    test "is a no-op for unknown stripe_id" do
      assert {:ok, :transaction_not_found} =
               DatabaseOperations.process_failed_payment("cs_never_existed")
    end
  end
end
