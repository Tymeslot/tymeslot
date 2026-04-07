defmodule Tymeslot.Payments.ComponentsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.Factory
  alias Tymeslot.Payments.{ChangesetHelpers, PendingTransactions, Validation}
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Repo

  setup :set_mox_from_context
  setup :verify_on_exit!

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
    test "returns nil when no pending transaction exists" do
      user = Factory.insert(:user)

      assert {:ok, nil} = PendingTransactions.get_pending_transaction_for_user(user.id)
    end

    test "returns the pending transaction for a user" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: "pending"
        )

      assert {:ok, %{id: pending_id}} =
               PendingTransactions.get_pending_transaction_for_user(user.id)

      assert pending_id == pending_tx.id
    end

    test "returns pending transactions and supersedes them" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: "pending",
          metadata: %{"source" => "test"}
        )

      assert {:ok, [%{id: pending_id}]} =
               PendingTransactions.get_pending_transactions_for_user(user.id)

      assert pending_id == pending_tx.id

      assert :ok = PendingTransactions.supersede_pending_transaction(pending_tx)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == "failed"
      assert updated.metadata["superseded"] == true
    end

    test "supersede_pending_transaction/1 does not call Stripe when stripe_id is not a checkout session" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: "pending",
          stripe_id: "pi_abc123"
        )

      # No Stripe mock expectation — if expire_checkout_session were called, verify_on_exit! would fail
      assert :ok = PendingTransactions.supersede_pending_transaction(pending_tx)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == "failed"
    end

    test "supersede_pending_transaction_if_needed/1 returns ok with no pending transactions" do
      user = Factory.insert(:user)

      assert :ok = PendingTransactions.supersede_pending_transaction_if_needed(user.id)
    end

    test "supersede_pending_transaction_if_needed/1 supersedes pending transactions" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: "pending"
        )

      assert :ok = PendingTransactions.supersede_pending_transaction_if_needed(user.id)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == "failed"
      assert updated.metadata["superseded"] == true
    end
  end

  describe "PendingTransactions checkout session expiry" do
    setup do
      original = Application.get_env(:tymeslot, :stripe_provider)
      Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)
      on_exit(fn -> Application.put_env(:tymeslot, :stripe_provider, original) end)
      :ok
    end

    test "expires the Stripe checkout session when stripe_id is a checkout session" do
      user = Factory.insert(:user)
      session_id = "cs_live_abc123"

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: "pending",
          stripe_id: session_id
        )

      expect(Tymeslot.Payments.StripeMock, :expire_checkout_session, fn ^session_id ->
        {:ok, %{id: session_id, status: "expired"}}
      end)

      assert :ok = PendingTransactions.supersede_pending_transaction(pending_tx)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == "failed"
      assert updated.metadata["superseded"] == true
    end

    test "proceeds even when Stripe session expiry fails" do
      user = Factory.insert(:user)
      session_id = "cs_live_abc123"

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: "pending",
          stripe_id: session_id
        )

      expect(Tymeslot.Payments.StripeMock, :expire_checkout_session, fn ^session_id ->
        {:error, %{message: "Session already expired"}}
      end)

      assert :ok = PendingTransactions.supersede_pending_transaction(pending_tx)

      updated = Repo.get!(PaymentTransactionSchema, pending_tx.id)
      assert updated.status == "failed"
      assert updated.metadata["superseded"] == true
    end
  end
end
