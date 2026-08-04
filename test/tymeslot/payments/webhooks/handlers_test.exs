defmodule Tymeslot.Payments.Webhooks.HandlersTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

  alias Tymeslot.Payments.Webhooks.{
    ChargeHandler,
    CheckoutSessionExpiredHandler,
    CheckoutSessionHandler,
    CustomerHandler,
    PaymentIntentHandler
  }

  alias Tymeslot.Factory
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Repo

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "ChargeHandler" do
    test "can_handle?/1" do
      assert ChargeHandler.can_handle?("charge.succeeded")
      assert ChargeHandler.can_handle?("charge.failed")
      refute ChargeHandler.can_handle?("charge.refunded")
    end

    test "validate/1 always returns :ok" do
      assert ChargeHandler.validate(%{}) == :ok
    end

    test "process/2 logs and returns success for charge.succeeded" do
      assert {:ok, :charge_logged} =
               ChargeHandler.process(%{type: "charge.succeeded"}, %{"id" => "ch_123"})
    end

    test "process/2 logs and returns success for charge.failed" do
      assert {:ok, :charge_failed_logged} =
               ChargeHandler.process(%{type: "charge.failed"}, %{"id" => "ch_123"})
    end
  end

  describe "CustomerHandler" do
    test "can_handle?/1" do
      assert CustomerHandler.can_handle?("customer.created")
      assert CustomerHandler.can_handle?("customer.updated")
      refute CustomerHandler.can_handle?("customer.deleted")
    end

    test "validate/1 checks for id" do
      assert CustomerHandler.validate(%{"id" => "cus_123"}) == :ok
      assert CustomerHandler.validate(%{id: "cus_123"}) == :ok
      assert {:error, :missing_field, _message} = CustomerHandler.validate(%{})
    end

    test "process/2 returns success for customer.created" do
      assert {:ok, :customer_created} =
               CustomerHandler.process(%{type: "customer.created"}, %{"id" => "cus_123"})
    end

    test "process/2 returns success for customer.updated" do
      assert {:ok, :customer_updated} =
               CustomerHandler.process(%{type: "customer.updated"}, %{"id" => "cus_123"})
    end
  end

  describe "PaymentIntentHandler" do
    test "can_handle?/1" do
      assert PaymentIntentHandler.can_handle?("payment_intent.succeeded")
      assert PaymentIntentHandler.can_handle?("payment_intent.created")
      refute PaymentIntentHandler.can_handle?("payment_intent.failed")
    end

    test "validate/1 always returns :ok" do
      assert PaymentIntentHandler.validate(%{}) == :ok
    end

    test "process/2 returns success for payment_intent.succeeded" do
      assert {:ok, :payment_intent_logged} =
               PaymentIntentHandler.process(%{type: "payment_intent.succeeded"}, %{
                 "id" => "pi_123"
               })
    end

    test "process/2 returns success for payment_intent.created" do
      assert {:ok, :payment_intent_logged} =
               PaymentIntentHandler.process(%{type: "payment_intent.created"}, %{"id" => "pi_123"})
    end
  end

  describe "CheckoutSessionHandler" do
    test "can_handle?/1" do
      assert CheckoutSessionHandler.can_handle?("checkout.session.completed")
      refute CheckoutSessionHandler.can_handle?("checkout.session.expired")
    end

    test "validate/1 checks for id" do
      assert CheckoutSessionHandler.validate(%{"id" => "cs_123"}) == :ok
      assert {:error, :missing_field, "Session ID missing"} = CheckoutSessionHandler.validate(%{})

      assert {:error, :missing_field, "Session ID empty"} =
               CheckoutSessionHandler.validate(%{"id" => ""})
    end

    test "process/2 ignores an unexpected (non-subscription) mode" do
      session = %{"id" => "cs_123", "mode" => "payment"}

      # The platform account only ever creates subscription-mode sessions;
      # paid bookings run through the separate Connect checkout and its own
      # webhook endpoint. Any other mode here is unexpected and must not be
      # silently treated as a processed payment.
      assert {:ok, :ignored} =
               CheckoutSessionHandler.process(%{type: "checkout.session.completed"}, session)
    end

    test "process/2 handles subscription mode" do
      session = %{"id" => "cs_123", "mode" => "subscription"}

      # Mock subscription manager
      defmodule MockSubManager do
        @spec handle_checkout_completed(map()) :: {:ok, map()}
        def handle_checkout_completed(_session), do: {:ok, %{}}
      end

      Application.put_env(:tymeslot, :subscription_manager, MockSubManager)

      assert {:ok, :subscription_processed} =
               CheckoutSessionHandler.process(%{type: "checkout.session.completed"}, session)

      Application.delete_env(:tymeslot, :subscription_manager)
    end

    test "process/2 returns error when subscription manager is missing" do
      session = %{"id" => "cs_123", "mode" => "subscription"}
      Application.delete_env(:tymeslot, :subscription_manager)

      assert {:error, :subscriptions_not_supported, _error_message} =
               CheckoutSessionHandler.process(%{type: "checkout.session.completed"}, session)
    end
  end

  describe "CheckoutSessionExpiredHandler" do
    test "can_handle?/1" do
      assert CheckoutSessionExpiredHandler.can_handle?("checkout.session.expired")
      refute CheckoutSessionExpiredHandler.can_handle?("checkout.session.completed")
    end

    test "validate/1 checks for id" do
      assert CheckoutSessionExpiredHandler.validate(%{"id" => "cs_123"}) == :ok

      assert {:error, :missing_field, "Session ID missing"} =
               CheckoutSessionExpiredHandler.validate(%{})

      assert {:error, :missing_field, "Session ID empty"} =
               CheckoutSessionExpiredHandler.validate(%{"id" => ""})
    end

    test "process/2 handles expired session" do
      user = Factory.insert(:user)

      Factory.insert(:payment_transaction,
        user: user,
        stripe_id: "cs_expired",
        status: "pending"
      )

      session = %{"id" => "cs_expired"}

      assert {:ok, :event_processed} =
               CheckoutSessionExpiredHandler.process(%{type: "checkout.session.expired"}, session)

      tx =
        Repo.get_by(PaymentTransactionSchema,
          stripe_id: "cs_expired"
        )

      assert tx.status == "failed"
    end

    test "process/2 handles expired session when transaction not found" do
      session = %{"id" => "cs_not_found"}
      # Handler returns :event_processed even when transaction is not found
      # (process_failed_payment returns {:ok, :transaction_not_found} which is treated as success)
      assert {:ok, :event_processed} =
               CheckoutSessionExpiredHandler.process(%{type: "checkout.session.expired"}, session)
    end
  end
end
