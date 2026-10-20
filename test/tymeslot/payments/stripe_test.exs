defmodule Tymeslot.Payments.StripeTest do
  # async: false: The :stripe_* module keys and :api_key are read through Payments.Config by
  # every payment path, so swapping them reaches far past this module.
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  import Mox

  alias Tymeslot.Payments.Stripe
  # Avoid alias conflicts by using the full module name for the struct
  # or just use the map form if the struct isn't available at compile time

  # We mock the underlying Stripe modules that the Stripe wrapper uses
  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Configure the wrapper to use our mocks instead of the real Stripe modules
    Application.put_env(:tymeslot, :stripe_customer_mod, StripeCustomerMock)
    Application.put_env(:tymeslot, :stripe_session_mod, StripeSessionMock)
    Application.put_env(:tymeslot, :stripe_subscription_mod, StripeSubscriptionMock)
    Application.put_env(:tymeslot, :stripe_secret_key, "sk_test_fake")

    on_exit(fn ->
      Application.delete_env(:tymeslot, :stripe_customer_mod)
      Application.delete_env(:tymeslot, :stripe_session_mod)
      Application.delete_env(:tymeslot, :stripe_subscription_mod)
      Application.delete_env(:tymeslot, :stripe_secret_key)
    end)

    :ok
  end

  describe "create_customer/1" do
    test "successfully creates a customer" do
      email = "test@example.com"

      expect(StripeCustomerMock, :create, fn params, opts ->
        assert params.email == email
        assert opts[:api_key] == "sk_test_fake"
        {:ok, %{id: "cus_123", email: email}}
      end)

      assert {:ok, %{id: "cus_123"}} = Stripe.create_customer(email)
    end

    test "makes one attempt and hands a network error back to the caller" do
      expect(StripeCustomerMock, :create, 1, fn _params, _opts ->
        {:error, %{__struct__: Stripe.Error, source: :network, message: "Network timeout"}}
      end)

      assert {:error, %{source: :network}} = Stripe.create_customer("test@example.com")
    end
  end

  describe "expire_checkout_session/1" do
    test "successfully expires a checkout session" do
      session_id = "cs_live_abc123"

      expect(StripeSessionMock, :expire, fn ^session_id, %{}, _opts ->
        {:ok, %{id: session_id, status: "expired"}}
      end)

      assert {:ok, %{status: "expired"}} = Stripe.expire_checkout_session(session_id)
    end

    test "returns error when session cannot be expired" do
      session_id = "cs_live_abc123"

      expect(StripeSessionMock, :expire, 1, fn ^session_id, %{}, _opts ->
        {:error, %{__struct__: Stripe.Error, source: :network, message: "Network timeout"}}
      end)

      assert {:error, %{source: :network}} = Stripe.expire_checkout_session(session_id)
    end
  end

  describe "delete_customer/1" do
    test "deletes the customer at Stripe" do
      expect(StripeCustomerMock, :delete, fn "cus_123", opts ->
        assert opts[:api_key] == "sk_test_fake"
        {:ok, %{id: "cus_123", deleted: true}}
      end)

      assert {:ok, %{deleted: true}} = Stripe.delete_customer("cus_123")
    end
  end

  describe "cancel_subscription/2" do
    test "uses a caller-supplied idempotency key" do
      expect(StripeSubscriptionMock, :update, fn "sub_123", params, opts ->
        assert params == %{cancel_at_period_end: true}
        assert opts[:idempotency_key] == "my-key"
        {:ok, %{id: "sub_123", cancel_at_period_end: true}}
      end)

      assert {:ok, _sub} =
               Stripe.cancel_subscription("sub_123",
                 at_period_end: true,
                 idempotency_key: "my-key"
               )
    end

    test "defaults to a key scoped to the operation, subscription and day" do
      expect(StripeSubscriptionMock, :update, fn "sub_123", _params, opts ->
        assert opts[:idempotency_key] =~ ~r/^subscription_cancel_at_period_end_/
        {:ok, %{id: "sub_123"}}
      end)

      assert {:ok, _sub} = Stripe.cancel_subscription("sub_123", at_period_end: true)
    end
  end

  describe "resume_subscription/1" do
    test "turns cancel-at-period-end back off" do
      expect(StripeSubscriptionMock, :update, fn "sub_123", params, opts ->
        assert params == %{cancel_at_period_end: false}
        assert opts[:api_key] == "sk_test_fake"
        {:ok, %{id: "sub_123", cancel_at_period_end: false}}
      end)

      assert {:ok, %{cancel_at_period_end: false}} = Stripe.resume_subscription("sub_123")
    end
  end

  describe "list_charges/1" do
    setup do
      Application.put_env(:tymeslot, :stripe_charge_mod, StripeChargeMock)
      on_exit(fn -> Application.delete_env(:tymeslot, :stripe_charge_mod) end)
    end

    test "passes Stripe's filters through and returns the page" do
      params = %{customer: "cus_1", expand: ["data.refunds"], limit: 100}

      expect(StripeChargeMock, :list, fn ^params, opts ->
        assert opts[:api_key] == "sk_test_fake"
        {:ok, %{data: [%{id: "ch_1"}], has_more: false}}
      end)

      assert {:ok, %{data: [%{id: "ch_1"}]}} = Stripe.list_charges(params)
    end
  end

  describe "list_invoices/1" do
    setup do
      Application.put_env(:tymeslot, :stripe_invoice_mod, StripeInvoiceMock)
      on_exit(fn -> Application.delete_env(:tymeslot, :stripe_invoice_mod) end)
    end

    test "passes Stripe's filters through and returns the page" do
      params = %{subscription: "sub_123", status: "paid", limit: 100}

      expect(StripeInvoiceMock, :list, fn ^params, opts ->
        assert opts[:api_key] == "sk_test_fake"
        {:ok, %{data: [%{id: "in_1"}], has_more: false}}
      end)

      assert {:ok, %{data: [%{id: "in_1"}]}} = Stripe.list_invoices(params)
    end
  end

  describe "get_invoice/1" do
    setup do
      Application.put_env(:tymeslot, :stripe_invoice_mod, StripeInvoiceMock)
      on_exit(fn -> Application.delete_env(:tymeslot, :stripe_invoice_mod) end)
    end

    test "retrieves the invoice by id" do
      expect(StripeInvoiceMock, :retrieve, fn "in_1", %{}, opts ->
        assert opts[:api_key] == "sk_test_fake"
        {:ok, %{id: "in_1", subscription: "sub_1"}}
      end)

      assert {:ok, %{id: "in_1", subscription: "sub_1"}} = Stripe.get_invoice("in_1")
    end
  end

  describe "list_invoice_payments/1" do
    setup do
      Application.put_env(:tymeslot, :stripe_invoice_payment_mod, StripeInvoicePaymentMock)
      on_exit(fn -> Application.delete_env(:tymeslot, :stripe_invoice_payment_mod) end)
    end

    test "passes Stripe's filters through and returns the page" do
      params = %{payment: %{type: "payment_intent", payment_intent: "pi_1"}}

      expect(StripeInvoicePaymentMock, :list, fn ^params, opts ->
        assert opts[:api_key] == "sk_test_fake"
        {:ok, %{data: [%{invoice: "in_1"}], has_more: false}}
      end)

      assert {:ok, %{data: [%{invoice: "in_1"}]}} = Stripe.list_invoice_payments(params)
    end
  end

  describe "update_subscription_automatic_tax/2" do
    test "sets automatic tax to the given value" do
      expect(StripeSubscriptionMock, :update, fn "sub_123", params, opts ->
        assert params == %{automatic_tax: %{enabled: true}}
        assert opts[:api_key] == "sk_test_fake"
        refute Keyword.has_key?(opts, :idempotency_key)
        {:ok, %{id: "sub_123", automatic_tax: params.automatic_tax}}
      end)

      assert {:ok, %{automatic_tax: %{enabled: true}}} =
               Stripe.update_subscription_automatic_tax("sub_123", true)
    end

    test "passes a Stripe error back" do
      expect(StripeSubscriptionMock, :update, fn "sub_123", _params, _opts ->
        {:error, %{message: "No such subscription"}}
      end)

      assert {:error, %{message: "No such subscription"}} =
               Stripe.update_subscription_automatic_tax("sub_123", false)
    end
  end

  describe "error handling" do
    test "returns error when API key is missing" do
      Application.delete_env(:tymeslot, :stripe_secret_key)
      # Also ensure stripity_stripe doesn't have it
      old_key = Application.get_env(:stripity_stripe, :api_key)
      Application.delete_env(:stripity_stripe, :api_key)

      assert {:error, :missing_api_key} = Stripe.create_customer("test@example.com")

      # Restore
      if old_key, do: Application.put_env(:stripity_stripe, :api_key, old_key)
    end
  end
end
