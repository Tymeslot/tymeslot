defmodule Tymeslot.Payments.StripeApiTest do
  # async: false: the configured-key test changes global config.
  use ExUnit.Case, async: false

  @moduletag :payments

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Payments
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  # {context function, args, Stripe operation, fixture, method, path, form or query it sends}
  @operations [
    {:create_stripe_customer, [%{email: "a@example.com"}], :create_customer, "customer", :post,
     "/v1/customers", %{"email" => "a@example.com"}},
    {:delete_stripe_customer, ["cus_1"], :delete_customer, "customer_deleted", :delete,
     "/v1/customers/cus_1", %{}},
    {:create_stripe_subscription_checkout, [%{mode: "subscription"}], :create_checkout_session,
     "checkout_session_subscription", :post, "/v1/checkout/sessions",
     %{"mode" => "subscription"}},
    {:create_stripe_billing_portal_session, ["cus_1", "https://example.com/back"],
     :create_billing_portal_session, "billing_portal_session", :post,
     "/v1/billing_portal/sessions",
     %{"customer" => "cus_1", "return_url" => "https://example.com/back"}},
    {:get_stripe_subscription, ["sub_1"], :retrieve_subscription, "subscription", :get,
     "/v1/subscriptions/sub_1", %{}},
    {:list_stripe_subscriptions, [%{customer: "cus_1"}], :list_subscriptions, :list, :get,
     "/v1/subscriptions", %{"customer" => "cus_1"}},
    {:cancel_stripe_subscription, ["sub_1", [at_period_end: false]], :cancel_subscription,
     "subscription_canceled", :delete, "/v1/subscriptions/sub_1", %{}},
    {:resume_stripe_subscription, ["sub_1"], :update_subscription, "subscription", :post,
     "/v1/subscriptions/sub_1", %{"cancel_at_period_end" => "false"}},
    {:set_stripe_subscription_automatic_tax, ["sub_1", true], :update_subscription,
     "subscription", :post, "/v1/subscriptions/sub_1",
     %{"automatic_tax" => %{"enabled" => "true"}}},
    {:list_stripe_invoices, [%{customer: "cus_1"}], :list_invoices, :list, :get, "/v1/invoices",
     %{"customer" => "cus_1"}},
    {:list_stripe_charges, [%{customer: "cus_1", limit: 100}], :list_charges, :list, :get,
     "/v1/charges", %{"customer" => "cus_1", "limit" => "100"}},
    {:create_stripe_refund, [%{charge: "ch_1"}, [idempotency_key: "k"]], :create_refund, "refund",
     :post, "/v1/refunds", %{"charge" => "ch_1"}}
  ]

  describe "Stripe API pass-throughs" do
    for {fun, args, operation, fixture, method, path, sent} <- @operations do
      test "#{fun} sends one #{operation} request and returns Stripe's object as sent" do
        fun = unquote(fun)
        args = unquote(Macro.escape(args))
        operation = unquote(operation)
        method = unquote(method)
        path = unquote(path)
        sent = unquote(Macro.escape(sent))

        response = response_fixture(unquote(fixture))
        StripeStub.expect(operation, 1, response)

        assert apply(Payments, fun, args) == {:ok, response}

        assert [%{operation: ^operation, method: ^method, path: ^path} = request] =
                 StripeStub.requests()

        params = if method == :get, do: request.query, else: request.form
        assert Map.take(params, Map.keys(sent)) == sent
      end
    end

    test "passes a Stripe error through" do
      StripeStub.expect(:retrieve_subscription, {:error_fixture, "resource_missing"})

      assert {:error, %Error{code: "resource_missing", status: 404}} =
               Payments.get_stripe_subscription("sub_1")
    end
  end

  describe "keys and parameters the platform calls carry" do
    test "create_stripe_customer keeps the day-scoped key and default metadata" do
      StripeStub.expect(:create_customer, StripeFixtures.object("customer"))

      assert {:ok, _customer} = Payments.create_stripe_customer("a@example.com")

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_customer)
      assert form["email"] == "a@example.com"
      assert form["metadata"] == %{"is_business" => "pending"}
      assert headers["idempotency-key"] == legacy_key("customer_create", "a@example.com")
    end

    test "create_stripe_subscription_checkout keys on the checkout request id" do
      StripeStub.expect(
        :create_checkout_session,
        StripeFixtures.object("checkout_session_subscription")
      )

      assert {:ok, _session} =
               Payments.create_stripe_subscription_checkout(%{
                 mode: "subscription",
                 line_items: [%{price: "price_1", quantity: 1}],
                 metadata: %{"checkout_request_id" => "req_1"}
               })

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_checkout_session)
      assert [%{"price" => "price_1"}] = form["line_items"]
      assert headers["idempotency-key"] == legacy_key("subscription_checkout", "req_1")
    end

    test "cancel at period end posts the flag under the default key, or the caller's" do
      StripeStub.expect(:update_subscription, 2, StripeFixtures.object("subscription_canceling"))

      assert {:ok, _subscription} = Payments.cancel_stripe_subscription("sub_1", [])

      assert {:ok, _subscription} =
               Payments.cancel_stripe_subscription("sub_1", idempotency_key: "own")

      assert [default, own] = StripeStub.requests(:update_subscription)

      for request <- [default, own] do
        assert %{method: :post, path: "/v1/subscriptions/sub_1"} = request
        assert request.form == %{"cancel_at_period_end" => "true"}
      end

      assert default.headers["idempotency-key"] ==
               legacy_key("subscription_cancel_at_period_end", "sub_1")

      assert own.headers["idempotency-key"] == "own"
    end

    test "cancel now deletes without a key" do
      StripeStub.expect(:cancel_subscription, StripeFixtures.object("subscription_canceled"))

      assert {:ok, %{"status" => "canceled"}} =
               Payments.cancel_stripe_subscription("sub_1", at_period_end: false)

      assert [%{method: :delete, path: "/v1/subscriptions/sub_1", headers: headers}] =
               StripeStub.requests()

      refute Map.has_key?(headers, "idempotency-key")
    end

    test "create_stripe_refund requires a key" do
      StripeStub.stub(:create_refund, StripeFixtures.object("refund"))

      assert_raise KeyError, fn -> Payments.create_stripe_refund(%{charge: "ch_1"}, []) end
      assert StripeStub.requests() == []
    end
  end

  describe "stripe_configured?/0" do
    test "stripe_configured? follows the configured key" do
      with_config(:tymeslot, stripe_secret_key: nil)
      with_config(:stripity_stripe, api_key: nil)
      refute Payments.stripe_configured?()

      with_config(:tymeslot, stripe_secret_key: "sk_test_x")
      assert Payments.stripe_configured?()
    end
  end

  defp response_fixture(:list), do: StripeFixtures.list([])
  defp response_fixture(name), do: StripeFixtures.object(name)

  # The day-scoped key format the platform calls send.
  defp legacy_key(operation, identifier) do
    hash =
      :sha256
      |> :crypto.hash(identifier)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "#{operation}_#{hash}_#{Calendar.strftime(Date.utc_today(), "%Y%m%d")}"
  end
end
