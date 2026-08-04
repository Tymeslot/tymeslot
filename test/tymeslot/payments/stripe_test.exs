defmodule Tymeslot.Payments.StripeTest do
  use Tymeslot.DataCase, async: true
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
    Application.put_env(:tymeslot, :stripe_webhook_mod, StripeWebhookMock)
    Application.put_env(:tymeslot, :stripe_secret_key, "sk_test_fake")

    on_exit(fn ->
      Application.delete_env(:tymeslot, :stripe_customer_mod)
      Application.delete_env(:tymeslot, :stripe_session_mod)
      Application.delete_env(:tymeslot, :stripe_subscription_mod)
      Application.delete_env(:tymeslot, :stripe_webhook_mod)
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

    test "retries on network errors" do
      email = "test@example.com"

      # First attempt fails with network error, second succeeds
      expect(StripeCustomerMock, :create, 1, fn _params, _opts ->
        {:error, %{__struct__: Stripe.Error, source: :network, message: "Network timeout"}}
      end)

      expect(StripeCustomerMock, :create, 1, fn _params, _opts ->
        {:ok, %{id: "cus_123"}}
      end)

      assert {:ok, %{id: "cus_123"}} = Stripe.create_customer(email)
    end

    test "fails after max retries" do
      email = "test@example.com"

      expect(StripeCustomerMock, :create, 3, fn _params, _opts ->
        {:error, %{__struct__: Stripe.Error, source: :network, message: "Network timeout"}}
      end)

      assert {:error, %{source: :network}} = Stripe.create_customer(email)
    end
  end

  describe "update_subscription/3" do
    test "successfully updates subscription by finding the first item" do
      sub_id = "sub_123"
      new_price = "price_456"

      expect(StripeSubscriptionMock, :retrieve, fn ^sub_id, _params, _opts ->
        {:ok, %{id: sub_id, items: %{data: [%{id: "si_123"}]}}}
      end)

      expect(StripeSubscriptionMock, :update, fn ^sub_id, params, _opts ->
        assert [%{id: "si_123", price: ^new_price}] = params.items
        {:ok, %{id: sub_id}}
      end)

      assert {:ok, %{id: "sub_123"}} = Stripe.update_subscription(sub_id, new_price)
    end

    test "returns error if no subscription items found" do
      sub_id = "sub_123"
      new_price = "price_456"

      expect(StripeSubscriptionMock, :retrieve, fn ^sub_id, _params, _opts ->
        {:ok, %{id: sub_id, items: %{data: []}}}
      end)

      assert {:error, :no_subscription_items} = Stripe.update_subscription(sub_id, new_price)
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

      expect(StripeSessionMock, :expire, 3, fn ^session_id, %{}, _opts ->
        {:error, %{__struct__: Stripe.Error, source: :network, message: "Network timeout"}}
      end)

      assert {:error, %{source: :network}} = Stripe.expire_checkout_session(session_id)
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
