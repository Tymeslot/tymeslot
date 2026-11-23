defmodule Tymeslot.Payments.PlatformBillingTest do
  use ExUnit.Case, async: true

  @moduletag :payments

  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Payments.PlatformBilling
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  describe "keys and parameters the platform calls carry" do
    test "a customer created for a checkout is keyed by that checkout" do
      StripeStub.expect(:create_customer, StripeFixtures.object("customer"))

      assert {:ok, _customer} =
               PlatformBilling.create_customer(%{email: "a@example.com"}, intent_id: "req_1")

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_customer)
      assert form["email"] == "a@example.com"
      assert form["metadata"] == %{"is_business" => "pending"}
      assert headers["idempotency-key"] == "tymeslot:customer:req_1"
    end

    test "find_customer returns the newest customer of that user for the email" do
      older =
        StripeFixtures.object("customer", %{
          "id" => "cus_old",
          "created" => 1,
          "metadata" => %{"user_id" => "7"}
        })

      newer =
        StripeFixtures.object("customer", %{
          "id" => "cus_new",
          "created" => 2,
          "metadata" => %{"user_id" => "7"}
        })

      other =
        StripeFixtures.object("customer", %{
          "id" => "cus_other",
          "created" => 3,
          "metadata" => %{"user_id" => "8"}
        })

      StripeStub.expect(:list_customers, StripeFixtures.list([other, older, newer]))

      assert {:ok, %{"id" => "cus_new"}} = PlatformBilling.find_customer("a@example.com", 7)

      assert [%{query: query}] = StripeStub.requests(:list_customers)
      assert query["email"] == "a@example.com"
      assert query["limit"] == "10"
    end

    test "find_customer ignores another user's customer with the same email" do
      other = StripeFixtures.object("customer", %{"metadata" => %{"user_id" => "8"}})
      StripeStub.expect(:list_customers, StripeFixtures.list([other]))

      assert {:ok, nil} = PlatformBilling.find_customer("a@example.com", 7)
    end

    test "find_customer returns Stripe's error" do
      StripeStub.expect(:list_customers, {:error_fixture, "invalid_request_error"})

      assert {:error, %Error{}} = PlatformBilling.find_customer("a@example.com", 7)
    end

    test "a customer created without an intent gets a per-call key" do
      StripeStub.expect(:create_customer, 2, StripeFixtures.object("customer"))

      assert {:ok, _customer} = PlatformBilling.create_customer("a@example.com")
      assert {:ok, _customer} = PlatformBilling.create_customer("a@example.com")

      assert [first, second] = StripeStub.requests(:create_customer)
      assert "tymeslot-" <> _rest = first.headers["idempotency-key"]
      assert "tymeslot-" <> _rest = second.headers["idempotency-key"]
      refute first.headers["idempotency-key"] == second.headers["idempotency-key"]
    end

    test "a subscription checkout is keyed by its checkout request" do
      StripeStub.expect(
        :create_checkout_session,
        StripeFixtures.object("checkout_session_subscription")
      )

      assert {:ok, _session} =
               PlatformBilling.create_subscription_checkout(%{
                 mode: "subscription",
                 line_items: [%{price: "price_1", quantity: 1}],
                 metadata: %{"checkout_request_id" => "req_1"}
               })

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_checkout_session)
      assert [%{"price" => "price_1"}] = form["line_items"]
      assert headers["idempotency-key"] == "tymeslot:subscription_checkout:req_1"
    end

    test "cancelling at period end sends a fresh key each call" do
      StripeStub.expect(:update_subscription, 2, StripeFixtures.object("subscription_canceling"))

      assert {:ok, _subscription} = PlatformBilling.cancel_subscription("sub_1", [])
      assert {:ok, _subscription} = PlatformBilling.cancel_subscription("sub_1", [])

      assert [first, second] = StripeStub.requests(:update_subscription)

      for request <- [first, second] do
        assert %{method: :post, path: "/v1/subscriptions/sub_1"} = request
        assert request.form == %{"cancel_at_period_end" => "true"}
      end

      refute first.headers["idempotency-key"] == second.headers["idempotency-key"]
    end

    test "cancel rejects an idempotency key option" do
      assert_raise ArgumentError, fn ->
        PlatformBilling.cancel_subscription("sub_1", idempotency_key: "own")
      end
    end

    test "cancel now deletes without a key" do
      StripeStub.expect(:cancel_subscription, StripeFixtures.object("subscription_canceled"))

      assert {:ok, %{"status" => "canceled"}} =
               PlatformBilling.cancel_subscription("sub_1", at_period_end: false)

      assert [%{method: :delete, path: "/v1/subscriptions/sub_1", headers: headers}] =
               StripeStub.requests()

      refute Map.has_key?(headers, "idempotency-key")
    end
  end
end
