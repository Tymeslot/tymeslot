defmodule Tymeslot.Payments.ComponentsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

  alias Ecto.Changeset
  alias Tymeslot.Factory
  alias Tymeslot.Payments.{ChangesetHelpers, PendingTransactions, Validation}
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  describe "Validation.validate_amount/1" do
    test "accepts a valid amount" do
      assert :ok = Validation.validate_amount(100)
    end

    test "rejects values outside configured limits" do
      assert {:error, :invalid_amount} = Validation.validate_amount(10)
      assert {:error, :invalid_amount} = Validation.validate_amount(100_000_001)
    end

    test "rejects non-integer values" do
      assert {:error, :invalid_amount} = Validation.validate_amount("100")
    end
  end

  describe "ChangesetHelpers.unique_pending_transaction_error?/1" do
    test "detects uniqueness violation on user_id" do
      changeset =
        %PaymentTransactionSchema{}
        |> Changeset.change()
        |> Changeset.add_error(:user_id, "has already been taken", constraint: :unique)

      assert ChangesetHelpers.unique_pending_transaction_error?(changeset)
    end

    test "returns false for unrelated errors" do
      changeset =
        %PaymentTransactionSchema{}
        |> Changeset.change()
        |> Changeset.add_error(:user_id, "is invalid")

      refute ChangesetHelpers.unique_pending_transaction_error?(changeset)
    end
  end

  describe "PendingTransactions" do
    test "returns pending transactions and supersedes them" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: :pending,
          metadata: %{"source" => "test"}
        )

      assert {:ok, [%{id: pending_id}]} =
               PendingTransactions.get_pending_transactions_for_user(user.id)

      assert pending_id == pending_tx.id

      assert :ok = PendingTransactions.supersede_pending_transaction(pending_tx)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == :failed
      assert updated.metadata["superseded"] == true
    end

    test "supersede_pending_transaction/1 does not call Stripe when stripe_id is not a checkout session" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: :pending,
          stripe_id: "pi_abc123"
        )

      # No stub is installed, so a Stripe request would fail the test.
      assert :ok = PendingTransactions.supersede_pending_transaction(pending_tx)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == :failed
    end

    test "supersede_pending_transaction_if_needed/1 returns ok with no pending transactions" do
      user = Factory.insert(:user)

      assert :ok = PendingTransactions.supersede_pending_transaction_if_needed(user.id)
    end

    test "supersede_pending_transaction_if_needed/1 supersedes a pending transaction with a session" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: :pending,
          stripe_id: "pi_abc123"
        )

      assert :ok = PendingTransactions.supersede_pending_transaction_if_needed(user.id)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == :failed
      assert updated.metadata["superseded"] == true
    end

    test "supersede_pending_transaction_if_needed/1 leaves a checkout still being prepared" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction, user: user, status: :pending, stripe_id: nil)

      assert :ok = PendingTransactions.supersede_pending_transaction_if_needed(user.id)

      assert Repo.get!(PaymentTransactionSchema, pending_tx.id).status == :pending
    end

    test "supersede_pending_transaction_if_needed/1 supersedes a sessionless one past the cutoff" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: :pending,
          stripe_id: nil,
          inserted_at: DateTime.add(DateTime.utc_now(:second), -121)
        )

      assert :ok = PendingTransactions.supersede_pending_transaction_if_needed(user.id)

      assert Repo.get!(PaymentTransactionSchema, pending_tx.id).status == :failed
    end

    test "supersede_pending_transaction/1 leaves a transaction no longer pending" do
      user = Factory.insert(:user)
      completed = Factory.insert(:payment_transaction, user: user, status: :completed)

      assert :ok = PendingTransactions.supersede_pending_transaction(completed)

      assert Repo.get!(PaymentTransactionSchema, completed.id).status == :completed
    end
  end

  describe "PendingTransactions checkout session expiry" do
    test "expires the Stripe checkout session when stripe_id is a checkout session" do
      user = Factory.insert(:user)
      session_id = "cs_live_abc123"

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: :pending,
          stripe_id: session_id
        )

      StripeStub.expect(
        :expire_checkout_session,
        StripeFixtures.object("checkout_session_expired", %{"id" => session_id})
      )

      assert :ok = PendingTransactions.supersede_pending_transaction(pending_tx)

      assert [%{method: :post, path: "/v1/checkout/sessions/cs_live_abc123/expire"}] =
               StripeStub.requests()

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == :failed
      assert updated.metadata["superseded"] == true
    end

    test "proceeds even when Stripe session expiry fails" do
      user = Factory.insert(:user)
      session_id = "cs_live_abc123"

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: :pending,
          stripe_id: session_id
        )

      StripeStub.expect(:expire_checkout_session, {:error_fixture, "invalid_request_error"})

      assert :ok = PendingTransactions.supersede_pending_transaction(pending_tx)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == :failed
      assert updated.metadata["superseded"] == true
    end
  end
end
