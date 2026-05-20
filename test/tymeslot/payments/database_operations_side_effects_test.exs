defmodule Tymeslot.Payments.DatabaseOperationsSideEffectsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments

  import Tymeslot.Factory

  alias Tymeslot.Payments.DatabaseOperations
  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Repo

  setup do
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "payment:payment_successful")
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "payment:subscription_successful")
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "payment:subscription_failed")
    :ok
  end

  describe "process_successful_payment/3" do
    test "marks the transaction completed, persists tax/discount, and broadcasts" do
      user = insert(:user)

      tx =
        insert(:payment_transaction,
          user: user,
          status: "pending",
          stripe_id: "cs_ok_1"
        )

      tax_info = %{
        tax_amount: 200,
        tax_rate: Decimal.new("0.2"),
        tax_id: "EU123",
        is_eu_business: true,
        country_code: "DE",
        billing_address: %{"line1" => "Test Strasse"}
      }

      assert {:ok, :payment_processed} =
               DatabaseOperations.process_successful_payment(tx, tax_info, 50)

      reloaded = Repo.reload(tx)
      assert reloaded.status == "completed"
      assert reloaded.tax_amount == 200
      assert Decimal.equal?(reloaded.tax_rate, Decimal.new("0.2"))
      assert reloaded.tax_id == "EU123"
      assert reloaded.is_eu_business == true
      assert reloaded.country_code == "DE"
      assert reloaded.discount_amount == 50

      assert_received {:payment_successful, %{user_id: user_id, transaction: broadcast_tx}}
      assert user_id == user.id
      assert broadcast_tx.status == "completed"
    end

    test "looks up the transaction by stripe_id when given a string" do
      user = insert(:user)

      insert(:payment_transaction,
        user: user,
        status: "pending",
        stripe_id: "cs_lookup_2"
      )

      assert {:ok, :payment_processed} =
               DatabaseOperations.process_successful_payment("cs_lookup_2")

      assert_received {:payment_successful, _payload}
    end

    test "returns :transaction_not_found for an unknown stripe_id" do
      assert {:error, :transaction_not_found} =
               DatabaseOperations.process_successful_payment("cs_does_not_exist")

      refute_received {:payment_successful, _payload}
    end
  end

  describe "process_subscription_failure/2" do
    test "moves the transaction to pending_reconciliation, stores invoice metadata, and broadcasts" do
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

      assert_received {:subscription_failed,
                       %{user_id: user_id, subscription_id: ^subscription_id}}

      assert user_id == user.id
    end

    test "returns :subscription_not_found when no matching active subscription exists" do
      invoice = %{"id" => "in_orphan", "subscription" => "sub_orphan", "created" => 0}

      assert {:error, :subscription_not_found} =
               DatabaseOperations.process_subscription_failure("sub_orphan", invoice)

      refute_received {:subscription_failed, _payload}
    end
  end

  describe "update_transaction_for_subscription/4" do
    test "links the checkout session to a subscription_id and broadcasts subscription_successful" do
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

      assert_received {:subscription_successful,
                       %{user_id: user_id, subscription_id: ^subscription_id}}

      assert user_id == user.id
    end

    test "returns :transaction_not_found when the checkout session has no matching transaction" do
      assert {:error, :transaction_not_found} =
               DatabaseOperations.update_transaction_for_subscription(
                 "cs_missing",
                 "sub_x",
                 "completed",
                 %{}
               )

      refute_received {:subscription_successful, _payload}
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
