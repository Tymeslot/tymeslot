defmodule Tymeslot.Integrations.Stripe.ResourcesTest do
  use ExUnit.Case, async: true

  alias Plug.Conn
  alias Plug.Conn.Query
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.Integrations.Stripe.Accounts
  alias Tymeslot.Integrations.Stripe.BillingPortal
  alias Tymeslot.Integrations.Stripe.Charges
  alias Tymeslot.Integrations.Stripe.CheckoutSessions
  alias Tymeslot.Integrations.Stripe.Customers
  alias Tymeslot.Integrations.Stripe.Disputes
  alias Tymeslot.Integrations.Stripe.InvoicePayments
  alias Tymeslot.Integrations.Stripe.Invoices
  alias Tymeslot.Integrations.Stripe.PaymentIntents
  alias Tymeslot.Integrations.Stripe.Refunds
  alias Tymeslot.Integrations.Stripe.Subscriptions

  @moduletag :payments

  @opts [api_key: "sk_test_x"]
  @params %{"customer" => "cus_1", "metadata" => %{"k" => "v"}}
  @expand %{expand: ["latest_charge"]}

  # {{module, function, leading args}, operation, method, path, decoded params}
  @table [
    {{Customers, :create, [@params]}, :create_customer, "POST", "/v1/customers", @params},
    {{Customers, :list, [@params]}, :list_customers, "GET", "/v1/customers", @params},
    {{Customers, :delete, ["cus_1"]}, :delete_customer, "DELETE", "/v1/customers/cus_1", %{}},
    {{Subscriptions, :create, [@params]}, :create_subscription, "POST", "/v1/subscriptions",
     @params},
    {{Subscriptions, :retrieve, ["sub_1"]}, :retrieve_subscription, "GET",
     "/v1/subscriptions/sub_1", %{}},
    {{Subscriptions, :list, [@params]}, :list_subscriptions, "GET", "/v1/subscriptions", @params},
    {{Subscriptions, :update, ["sub_1", @params]}, :update_subscription, "POST",
     "/v1/subscriptions/sub_1", @params},
    {{Subscriptions, :cancel, ["sub_1", @params]}, :cancel_subscription, "DELETE",
     "/v1/subscriptions/sub_1", @params},
    {{CheckoutSessions, :create, [@params]}, :create_checkout_session, "POST",
     "/v1/checkout/sessions", @params},
    {{CheckoutSessions, :retrieve, ["cs_1"]}, :retrieve_checkout_session, "GET",
     "/v1/checkout/sessions/cs_1", %{}},
    {{CheckoutSessions, :expire, ["cs_1"]}, :expire_checkout_session, "POST",
     "/v1/checkout/sessions/cs_1/expire", %{}},
    {{Charges, :retrieve, ["ch_1"]}, :retrieve_charge, "GET", "/v1/charges/ch_1", %{}},
    {{Charges, :list, [@params]}, :list_charges, "GET", "/v1/charges", @params},
    {{Refunds, :create, [@params]}, :create_refund, "POST", "/v1/refunds", @params},
    {{Refunds, :list, [@params]}, :list_refunds, "GET", "/v1/refunds", @params},
    {{Refunds, :retrieve, ["re_1", @params]}, :retrieve_refund, "GET", "/v1/refunds/re_1",
     @params},
    {{Disputes, :list, [@params]}, :list_disputes, "GET", "/v1/disputes", @params},
    {{Invoices, :retrieve, ["in_1"]}, :retrieve_invoice, "GET", "/v1/invoices/in_1", %{}},
    {{Invoices, :list, [@params]}, :list_invoices, "GET", "/v1/invoices", @params},
    {{InvoicePayments, :list, [@params]}, :list_invoice_payments, "GET", "/v1/invoice_payments",
     @params},
    {{PaymentIntents, :retrieve, ["pi_1", @params]}, :retrieve_payment_intent, "GET",
     "/v1/payment_intents/pi_1", @params},
    {{PaymentIntents, :create, [@params]}, :create_payment_intent, "POST", "/v1/payment_intents",
     @params},
    {{Accounts, :retrieve_connected, ["acct_1"]}, :retrieve_account, "GET", "/v1/account", %{}},
    {{Accounts, :create, [@params]}, :create_account, "POST", "/v1/accounts", @params},
    {{Accounts, :delete, ["acct_1"]}, :delete_account, "DELETE", "/v1/accounts/acct_1", %{}},
    {{BillingPortal, :create_session, [@params]}, :create_billing_portal_session, "POST",
     "/v1/billing_portal/sessions", @params}
  ]

  defp capture(response \\ %{"id" => "obj_1"}) do
    test_pid = self()

    ReqTest.stub(Stripe, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)

      send(
        test_pid,
        {:req, conn.method, conn.request_path, conn.query_string, body, conn.req_headers}
      )

      ReqTest.json(conn, response)
    end)
  end

  defp header(headers, name), do: for({^name, v} <- headers, do: v)

  for row <- @table do
    @row row
    {_call, operation, method, path, _params} = row

    test "#{operation} sends #{method} #{path}" do
      capture()
      {{module, function, args}, operation, method, path, params} = @row

      assert {:ok, %{"id" => "obj_1"}} = apply(module, function, args ++ [@opts])

      assert_received {:req, sent_method, sent_path, query, body, headers}
      assert sent_method == method
      assert sent_path == path
      assert header(headers, "x-tymeslot-stripe-operation") == [Atom.to_string(operation)]

      sent = if method == "POST", do: body, else: query
      assert Query.decode(sent) == stringify(params)
    end
  end

  defp stringify(map), do: map |> Jason.encode!() |> Jason.decode!()

  test "retrieve_connected sends Stripe-Account" do
    capture()

    assert {:ok, _object} = Accounts.retrieve_connected("acct_1", @opts)

    assert_received {:req, "GET", "/v1/account", _query, _body, headers}
    assert header(headers, "stripe-account") == ["acct_1"]
  end

  test "retrieve_connected accepts an equal connect_account" do
    capture()

    assert {:ok, _object} =
             Accounts.retrieve_connected("acct_1", [connect_account: "acct_1"] ++ @opts)

    assert_received {:req, "GET", "/v1/account", _query, _body, headers}
    assert header(headers, "stripe-account") == ["acct_1"]
  end

  test "retrieve_connected rejects a conflicting connect_account" do
    assert_raise ArgumentError, fn ->
      Accounts.retrieve_connected("acct_1", connect_account: "acct_2")
    end
  end

  test "Connect calls pass Stripe-Account through opts" do
    capture()

    assert {:ok, _object} =
             Refunds.create(@params,
               api_key: "sk_test_x",
               connect_account: "acct_1",
               idempotency_key: "k"
             )

    assert_received {:req, "POST", "/v1/refunds", _query, _body, headers}
    assert header(headers, "stripe-account") == ["acct_1"]
    assert header(headers, "idempotency-key") == ["k"]
  end

  test "PaymentIntents.retrieve encodes expand in the query" do
    capture()

    assert {:ok, _object} = PaymentIntents.retrieve("pi_1", @expand, @opts)

    assert_received {:req, "GET", "/v1/payment_intents/pi_1", query, _body, _headers}
    assert Query.decode(query) == %{"expand" => %{"0" => "latest_charge"}}
  end
end
