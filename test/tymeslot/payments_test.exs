defmodule Tymeslot.PaymentsTest do
  @moduletag :utils
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.PaymentTransactionSchema
  alias Tymeslot.Factory
  alias Tymeslot.Payments
  alias Tymeslot.Repo
  import Mox

  setup :set_mox_from_context
  @moduletag :utils
  setup :verify_on_exit!

  setup do
    Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)
    :ok
  end

  describe "initiate_payment/7" do
    test "successfully initiates payment" do
      user = Factory.insert(:user)
      amount = 1000
      email = "test@example.com"

      expect_create_customer(email)

      expect_create_session(amount, "sess_123", "https://stripe.com/sess_123")

      assert {:ok, "https://stripe.com/sess_123"} =
               Payments.initiate_payment(
                 amount,
                 "Pro Plan",
                 user.id,
                 email,
                 "https://success",
                 "https://cancel"
               )
    end

    test "supersedes existing pending transaction" do
      user = Factory.insert(:user)

      Factory.insert(:payment_transaction,
        user: user,
        status: "pending",
        stripe_id: "old_sess"
      )

      amount = 2000
      email = "test@example.com"

      expect_create_customer(email)

      expect_create_session(amount, "sess_456", "https://stripe.com/sess_456")

      assert {:ok, "https://stripe.com/sess_456"} =
               Payments.initiate_payment(
                 amount,
                 "Pro Plan",
                 user.id,
                 email,
                 "https://success",
                 "https://cancel"
               )

      # Verify old transaction is failed/superseded
      old_tx =
        Repo.get_by(PaymentTransactionSchema,
          stripe_id: "old_sess"
        )

      assert old_tx.status == "failed"
      assert old_tx.metadata["superseded"] == true
    end

    test "returns error for invalid amount" do
      assert {:error, :invalid_amount} =
               Payments.initiate_payment(
                 10,
                 "Pro Plan",
                 1,
                 "test@example.com",
                 "https://success",
                 "https://cancel"
               )
    end
  end

  describe "process_successful_payment/3" do
    test "successfully processes payment" do
      user = Factory.insert(:user)

      Factory.insert(:payment_transaction,
        user: user,
        stripe_id: "sess_123",
        status: "pending"
      )

      expect(Tymeslot.Payments.StripeMock, :verify_session, fn "sess_123" ->
        {:ok, %{id: "sess_123"}}
      end)

      assert {:ok, :payment_processed} =
               Payments.process_successful_payment("sess_123", %{"tax" => 100})

      tx =
        Repo.get_by(PaymentTransactionSchema,
          stripe_id: "sess_123"
        )

      assert tx.status == "completed"
    end

    test "returns error when transaction not found" do
      expect(Tymeslot.Payments.StripeMock, :verify_session, fn "unknown" ->
        {:ok, %{id: "unknown"}}
      end)

      assert {:error, :transaction_not_found} =
               Payments.process_successful_payment("unknown", %{})
    end
  end

  describe "initiate_subscription/7" do
    test "successfully initiates subscription" do
      user = Factory.insert(:user)

      defmodule MockSubManager do
        @spec create_subscription_checkout(any(), any(), any(), any(), any(), any(), any()) ::
                {:ok, map()}
        def create_subscription_checkout(_price, _prod, _amt, _uid, _email, _urls, _meta) do
          {:ok,
           %{
             "id" => "cs_sub_123",
             "url" => "https://stripe.com/sub_123",
             "subscription" => "sub_123",
             "customer" => "cus_123"
           }}
        end
      end

      set_subscription_manager(MockSubManager)

      assert {:ok, %{checkout_url: "https://stripe.com/sub_123"}} =
               Payments.initiate_subscription(
                 "price_123",
                 "Pro Plan",
                 1500,
                 user.id,
                 "test@example.com",
                 %{success: "https://s", cancel: "https://c"}
               )

      tx =
        Repo.get_by(PaymentTransactionSchema,
          stripe_id: "cs_sub_123"
        )

      assert tx.subscription_id == "sub_123"
    end

    test "supersedes pending one-time transaction before subscription" do
      user = Factory.insert(:user)

      pending_tx =
        Factory.insert(:payment_transaction,
          user: user,
          status: "pending",
          stripe_id: "sess_one_time",
          metadata: %{"payment_type" => "one_time"}
        )

      defmodule MockSubManagerForSupersede do
        @spec create_subscription_checkout(any(), any(), any(), any(), any(), any(), any()) ::
                {:ok, map()}
        def create_subscription_checkout(_price, _prod, _amt, _uid, _email, _urls, _meta) do
          {:ok,
           %{
             "id" => "cs_sub_supersede",
             "url" => "https://stripe.com/sub_supersede",
             "subscription" => "sub_supersede",
             "customer" => "cus_123"
           }}
        end
      end

      set_subscription_manager(MockSubManagerForSupersede)

      assert {:ok, %{checkout_url: "https://stripe.com/sub_supersede"}} =
               Payments.initiate_subscription(
                 "price_123",
                 "Pro Plan",
                 1500,
                 user.id,
                 "test@example.com",
                 %{success: "https://s", cancel: "https://c"}
               )

      updated_pending = Repo.get!(PaymentTransactionSchema, pending_tx.id)

      assert updated_pending.status == "failed"
      assert updated_pending.metadata["superseded"] == true
    end

    test "returns checkout url even if transaction update fails" do
      user = Factory.insert(:user)

      Factory.insert(:payment_transaction,
        user: user,
        status: "completed",
        stripe_id: "cs_sub_conflict"
      )

      defmodule MockSubManagerForUpdateFailure do
        @spec create_subscription_checkout(any(), any(), any(), any(), any(), any(), any()) ::
                {:ok, map()}
        def create_subscription_checkout(_price, _prod, _amt, _uid, _email, _urls, _meta) do
          {:ok,
           %{
             "id" => "cs_sub_conflict",
             "url" => "https://stripe.com/sub_conflict",
             "subscription" => "sub_conflict",
             "customer" => "cus_123"
           }}
        end
      end

      set_subscription_manager(MockSubManagerForUpdateFailure)

      assert {:ok, %{checkout_url: "https://stripe.com/sub_conflict"}} =
               Payments.initiate_subscription(
                 "price_123",
                 "Pro Plan",
                 1500,
                 user.id,
                 "test@example.com",
                 %{success: "https://s", cancel: "https://c"}
               )

      pending_tx =
        Repo.get_by(PaymentTransactionSchema,
          user_id: user.id,
          status: "pending"
        )

      assert pending_tx
      assert is_nil(pending_tx.stripe_id)
      assert pending_tx.status == "pending"
    end
  end

  defp expect_create_customer(email) do
    expect(Tymeslot.Payments.StripeMock, :create_customer, fn ^email ->
      {:ok, %{id: "cus_123"}}
    end)
  end

  defp expect_create_session(amount, session_id, session_url) do
    expect(Tymeslot.Payments.StripeMock, :create_session, fn _customer,
                                                             ^amount,
                                                             _transaction,
                                                             _success,
                                                             _cancel ->
      {:ok, %{id: session_id, url: session_url}}
    end)
  end

  defp set_subscription_manager(manager) do
    Application.put_env(:tymeslot, :subscription_manager, manager)
    on_exit(fn -> Application.delete_env(:tymeslot, :subscription_manager) end)
    :ok
  end
end
