defmodule Tymeslot.Integrations.Stripe.LiveTest do
  @moduledoc """
  Exercises every Stripe call Tymeslot makes against Stripe's test mode and
  writes `tmp/stripe_live/report.json` and `report.md`. Run it with
  `STRIPE_TEST_SECRET_KEY=sk_test_... mix test --only stripe_live --max-cases 1`;
  `STRIPE_RECORD=1` rewrites the fixtures from the live responses instead of
  comparing against them. Without a key every step is recorded as skipped.
  """
  use ExUnit.Case, async: false

  @moduletag :payments
  @moduletag :stripe_live
  @moduletag skip: Tymeslot.Test.SuiteConfig.unless_included(:stripe_live)

  import Tymeslot.StripeLiveFlow

  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.Integrations.Stripe.Accounts
  alias Tymeslot.Integrations.Stripe.BillingPortal
  alias Tymeslot.Integrations.Stripe.Charges
  alias Tymeslot.Integrations.Stripe.CheckoutSessions
  alias Tymeslot.Integrations.Stripe.Customers
  alias Tymeslot.Integrations.Stripe.Disputes
  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Integrations.Stripe.IdempotencyKey
  alias Tymeslot.Integrations.Stripe.InvoicePayments
  alias Tymeslot.Integrations.Stripe.Invoices
  alias Tymeslot.Integrations.Stripe.Pagination
  alias Tymeslot.Integrations.Stripe.PaymentIntents
  alias Tymeslot.Integrations.Stripe.Refunds
  alias Tymeslot.Integrations.Stripe.Subscriptions
  alias Tymeslot.StripeLiveFlow
  alias Tymeslot.StripeLiveReport

  @missing_connect ~r/connect/i
  @tax_settings ~r/tax (settings|registration)|origin address|head office/i
  @connect_not_ready ~r/connect|capabilit|onboard|cannot currently|not enabled/i

  setup_all do
    key = "STRIPE_TEST_SECRET_KEY" |> System.get_env() |> blank_to_nil()

    if key && not String.starts_with?(key, "sk_test_") do
      raise "refusing to run the Stripe live suite with a non-test key"
    end

    report = StripeLiveReport.start()
    record? = key != nil and System.get_env("STRIPE_RECORD") == "1"
    if key, do: use_real_transport(key)

    on_exit(fn ->
      if key, do: StripeLiveFlow.cleanup(report)
      StripeLiveReport.write!(report, record?)
      Agent.stop(report)
    end)

    {:ok, report: report, live?: key != nil, record?: record?}
  end

  setup %{report: report, live?: live?, record?: record?} = context do
    name = context.test |> Atom.to_string() |> String.replace_prefix("test ", "")
    {:ok, flow: StripeLiveFlow.new(report, name, live?: live?, record?: record?)}
  end

  test "platform customer", %{flow: flow} do
    unix = System.os_time(:second)

    customer =
      step(flow, "Customers.create", fn ->
        flow |> create_customer(unix) |> then(&track(flow, :customer, &1))
      end)

    step(flow, "Subscriptions.list", [needs: [{"Customers.create", customer}]], fn ->
      Subscriptions.list(%{customer: id(customer), limit: 3})
    end)

    step(flow, "Customers.delete", [needs: [{"Customers.create", customer}]], fn ->
      Customers.delete(id(customer))
    end)

    step(flow, "Customers.delete (again)", [needs: [{"Customers.create", customer}]], fn ->
      expect_missing(Customers.delete(id(customer)))
    end)

    assert failed_steps(flow) == []
  end

  test "platform subscription", %{flow: flow} do
    unix = System.os_time(:second)

    customer =
      step(flow, "Customers.create (subscription flow)", fn ->
        flow |> create_customer(unix) |> then(&track(flow, :customer, &1))
      end)

    cust = [{"Customers.create (subscription flow)", customer}]

    product =
      step(flow, "products.create", fn ->
        raw_track(flow, :product, :create_product, ["products"], %{
          name: "Tymeslot live suite #{unix}"
        })
      end)

    price =
      step(flow, "prices.create", [needs: [{"products.create", product}]], fn ->
        raw_track(flow, :price, :create_price, ["prices"], %{
          product: id(product),
          unit_amount: 500,
          currency: "eur",
          recurring: %{interval: "month"}
        })
      end)

    prc = [{"prices.create", price}]

    session =
      step(flow, "CheckoutSessions.create (subscription)", [needs: cust ++ prc], fn ->
        CheckoutSessions.create(%{
          mode: "subscription",
          customer: id(customer),
          line_items: [%{price: id(price), quantity: 1}],
          success_url: "https://example.test/success?session_id={CHECKOUT_SESSION_ID}",
          cancel_url: "https://example.test/cancel"
        })
      end)

    step(
      flow,
      "CheckoutSessions.expire (subscription)",
      [needs: [{"CheckoutSessions.create (subscription)", session}]],
      fn ->
        CheckoutSessions.expire(id(session))
      end
    )

    # A paid subscription, so the recorded subscription and invoice fixtures
    # are `active` and `paid` as Tymeslot's own come back from Checkout.
    card =
      step(flow, "payment_methods.attach (pm_card_visa)", [needs: cust], fn ->
        raw(:attach_payment_method, :post, ["payment_methods", "pm_card_visa", "attach"], %{
          customer: id(customer)
        })
      end)

    sub =
      step(
        flow,
        "Subscriptions.create",
        [needs: cust ++ prc ++ [{"payment_methods.attach (pm_card_visa)", card}]],
        fn ->
          %{
            customer: id(customer),
            items: [%{price: id(price)}],
            default_payment_method: id(card),
            payment_behavior: "error_if_incomplete"
          }
          |> Subscriptions.create()
          |> then(&track(flow, :subscription, &1))
        end
      )

    sub_dep = [{"Subscriptions.create", sub}]

    step(flow, "Subscriptions.retrieve", [needs: sub_dep], fn ->
      Subscriptions.retrieve(id(sub))
    end)

    step(flow, "Subscriptions.update (cancel at period end)", [needs: sub_dep], fn ->
      Subscriptions.update(id(sub), %{cancel_at_period_end: true})
    end)

    step(flow, "Subscriptions.update (resume)", [needs: sub_dep], fn ->
      Subscriptions.update(id(sub), %{cancel_at_period_end: false})
    end)

    # Stripe Tax refuses a customer it cannot place, and Checkout collects the
    # address in production; the flow's customer has none until this step.
    step(flow, "customers.update (tax address)", [needs: cust], fn ->
      raw(:update_customer, :post, ["customers", id(customer)], %{
        address: %{
          line1: "Unter den Linden 1",
          city: "Berlin",
          postal_code: "10117",
          country: "DE"
        }
      })
    end)

    step(flow, "Subscriptions.update (automatic tax)", [needs: sub_dep], fn ->
      id(sub)
      |> Subscriptions.update(%{automatic_tax: %{enabled: true}})
      |> skip_if(@tax_settings)
    end)

    step(flow, "Subscriptions.cancel", [needs: sub_dep], fn ->
      Subscriptions.cancel(id(sub), %{})
    end)

    invoices =
      step(flow, "Invoices.list", [needs: cust], fn ->
        Invoices.list(%{customer: id(customer), limit: 3})
      end)

    invoice =
      step(flow, "First invoice exists", [needs: [{"Invoices.list", invoices}]], fn ->
        first_of(invoices, "Invoices.list")
      end)

    inv = [{"First invoice exists", invoice}]

    step(flow, "Invoices.retrieve", [needs: inv], fn -> Invoices.retrieve(id(invoice)) end)

    step(flow, "InvoicePayments.list", [needs: inv], fn ->
      InvoicePayments.list(%{invoice: id(invoice), limit: 3})
    end)

    step(flow, "BillingPortal.create_session", [needs: cust], fn ->
      %{customer: id(customer), return_url: "https://example.test/billing"}
      |> BillingPortal.create_session()
      |> skip_if(~r/configuration/i)
    end)

    assert failed_steps(flow) == []
  end

  test "platform charge and refund", %{flow: flow} do
    unix = System.os_time(:second)
    refund_ref = "live-#{unix}"
    key = IdempotencyKey.for_intent(:refund, refund_ref, 1)

    intent =
      step(flow, "PaymentIntents.create", fn ->
        PaymentIntents.create(%{
          amount: 1000,
          currency: "eur",
          payment_method: "pm_card_visa",
          confirm: true,
          automatic_payment_methods: %{enabled: true, allow_redirects: "never"}
        })
      end)

    pi = [{"PaymentIntents.create", intent}]

    retrieved =
      step(flow, "PaymentIntents.retrieve", [needs: pi], fn ->
        PaymentIntents.retrieve(id(intent), %{expand: ["latest_charge"]})
      end)

    charge =
      step(flow, "Latest charge present", [needs: [{"PaymentIntents.retrieve", retrieved}]], fn ->
        latest_charge(retrieved)
      end)

    charge_id = id(charge)
    ch = [{"Latest charge present", charge}]

    step(flow, "Charges.retrieve", [needs: ch], fn -> Charges.retrieve(charge_id) end)

    refund_params = %{
      charge: charge_id,
      amount: 300,
      metadata: %{tymeslot_refund_id: refund_ref},
      expand: ["charge"]
    }

    refund =
      step(flow, "Refunds.create", [needs: ch], fn ->
        Refunds.create(refund_params, idempotency_key: key)
      end)

    rf = [{"Refunds.create", refund}]

    step(flow, "Refunds.create (same key replays)", [needs: rf], fn ->
      with {:ok, replay} <- Refunds.create(refund_params, idempotency_key: key) do
        if replay["id"] == id(refund),
          do: {:ok, replay},
          else: {:error, {:exception, %RuntimeError{message: "replay returned #{replay["id"]}"}}}
      end
    end)

    step(flow, "Refunds.create (same key, other amount)", [needs: rf], fn ->
      case Refunds.create(%{refund_params | amount: 400}, idempotency_key: key) do
        {:error, %Error{type: "idempotency_error"} = error} ->
          {:recorded_error, error}

        {:ok, _refund} ->
          {:error,
           {:exception,
            %RuntimeError{message: "a different body reused the key without an error"}}}

        error ->
          error
      end
    end)

    step(flow, "Charges.list (expand refunds)", [needs: ch], fn ->
      Charges.list(%{payment_intent: id(intent), limit: 3, expand: ["data.refunds"]})
    end)

    step(flow, "Refunds.list", [needs: rf], fn ->
      with {:ok, %{"data" => refunds} = list} <-
             Refunds.list(%{charge: charge_id, limit: 10}) do
        if Enum.any?(refunds, &(&1["metadata"]["tymeslot_refund_id"] == refund_ref)),
          do: {:ok, list},
          else: {:error, {:exception, %RuntimeError{message: "refund not found by metadata"}}}
      end
    end)

    step(flow, "Refunds.retrieve", [needs: rf], fn -> Refunds.retrieve(id(refund)) end)

    step(flow, "Disputes.list", [needs: ch], fn ->
      Disputes.list(%{charge: charge_id, limit: 3})
    end)

    step(flow, "Pagination.stream (charges, limit 2)", &sample_charge_pages/0)

    assert failed_steps(flow) == []
  end

  test "connect", %{flow: flow} do
    unix = System.os_time(:second)

    account =
      step(flow, "Accounts.create", fn ->
        %{
          type: "express",
          country: "GB",
          capabilities: %{card_payments: %{requested: true}, transfers: %{requested: true}},
          # Checkout refuses an account without a name to show the payer.
          business_profile: %{name: "Tymeslot live suite"}
        }
        |> Accounts.create()
        |> skip_if(@missing_connect)
        |> then(&track(flow, :account, &1))
      end)

    acct = [{"Accounts.create", account}]
    opts = fn -> [connect_account: id(account)] end

    step(flow, "Accounts.retrieve_connected", [needs: acct], fn ->
      Accounts.retrieve_connected(id(account))
    end)

    session =
      step(flow, "CheckoutSessions.create (connect)", [needs: acct], fn ->
        connect_checkout_params(unix)
        |> CheckoutSessions.create(opts.())
        |> skip_if(@connect_not_ready)
      end)

    sess = [{"CheckoutSessions.create (connect)", session}]

    step(flow, "CheckoutSessions.retrieve (connect)", [needs: sess], fn ->
      CheckoutSessions.retrieve(id(session), opts.())
    end)

    step(flow, "CheckoutSessions.expire (connect)", [needs: sess], fn ->
      CheckoutSessions.expire(id(session), opts.())
    end)

    intent =
      step(flow, "PaymentIntents.create (connect)", [needs: acct], fn ->
        %{
          amount: 1000,
          currency: "gbp",
          payment_method: "pm_card_visa",
          confirm: true,
          automatic_payment_methods: %{enabled: true, allow_redirects: "never"}
        }
        |> PaymentIntents.create(opts.())
        |> skip_if(@connect_not_ready)
      end)

    retrieved =
      step(
        flow,
        "PaymentIntents.retrieve (connect)",
        [needs: [{"PaymentIntents.create (connect)", intent}]],
        fn ->
          PaymentIntents.retrieve(id(intent), %{expand: ["latest_charge"]}, opts.())
        end
      )

    charge =
      step(
        flow,
        "Latest charge present (connect)",
        [needs: [{"PaymentIntents.retrieve (connect)", retrieved}]],
        fn -> latest_charge(retrieved) end
      )

    charge_id = id(charge)
    ch = [{"Latest charge present (connect)", charge}]

    step(flow, "Charges.retrieve (connect)", [needs: ch], fn ->
      Charges.retrieve(charge_id, opts.())
    end)

    step(flow, "Refunds.create (connect)", [needs: ch], fn ->
      Refunds.create(%{charge: charge_id, amount: 300, expand: ["charge"]}, opts.())
    end)

    step(flow, "Accounts.delete", [needs: acct], fn -> Accounts.delete(id(account)) end)

    step(flow, "ConnectOAuth", fn -> {:skip, "needs a browser consent, not exercised"} end)

    assert failed_steps(flow) == []
  end

  test "client behaviour", %{flow: flow} do
    step(flow, "404 shape", fn ->
      case raw(:retrieve_charge, :get, ["charges", "ch_does_not_exist"], %{}) do
        {:error, %Error{status: 404, request_id: id} = error} when is_binary(id) ->
          {:recorded_error, error}

        other ->
          {:error,
           {:exception,
            %RuntimeError{
              message: "expected a 404 with a request id, got #{inspect(other, limit: 3)}"
            }}}
      end
    end)

    step(flow, "401 shape", fn ->
      case raw(:retrieve_charge, :get, ["charges", "ch_does_not_exist"], %{},
             api_key: "sk_test_invalid"
           ) do
        {:error, %Error{status: 401} = error} ->
          {:recorded_error, error}

        other ->
          {:error,
           {:exception, %RuntimeError{message: "expected a 401, got #{inspect(other, limit: 3)}"}}}
      end
    end)

    assert failed_steps(flow) == []
  end

  # Three pages of two, never the whole list: test-mode rate limits are low.
  defp sample_charge_pages do
    items = Enum.take(Pagination.stream(&Charges.list/2, %{limit: 2}, []), 5)

    if length(items) > 2,
      do: {:ok, items},
      else: {:skip, "fewer than three charges in the account, so no second page"}
  rescue
    error in Error -> {:error, error}
  end

  defp use_real_transport(key) do
    settings = Application.get_env(:tymeslot, Stripe, [])
    previous_key = Application.fetch_env(:tymeslot, :stripe_secret_key)
    live = Keyword.merge(settings, req_options: [], tag_requests: false, retry_base_ms: 250)

    Application.put_env(:tymeslot, Stripe, live)
    Application.put_env(:tymeslot, :stripe_secret_key, key)

    on_exit(fn ->
      Application.put_env(:tymeslot, Stripe, settings)

      case previous_key do
        {:ok, value} -> Application.put_env(:tymeslot, :stripe_secret_key, value)
        :error -> Application.delete_env(:tymeslot, :stripe_secret_key)
      end
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp create_customer(_flow, unix) do
    Customers.create(%{
      email: "stripe-live+#{unix}@example.test",
      name: "Stripe live suite"
    })
  end

  defp raw_track(flow, kind, operation, path, params) do
    StripeLiveFlow.track(flow, kind, raw(operation, :post, path, params))
  end

  defp id({:ok, %{"id" => id}}), do: id
  defp id(_other), do: nil

  defp latest_charge({:ok, %{"latest_charge" => %{"id" => _id} = charge}}), do: {:ok, charge}

  defp latest_charge(_other) do
    {:error,
     {:exception, %RuntimeError{message: "the payment intent has no expanded latest_charge"}}}
  end

  defp first_of({:ok, %{"data" => [first | _rest]}}, _label), do: {:ok, first}
  defp first_of({:ok, _empty}, label), do: {:skip, "#{label} returned no objects"}
  defp first_of(other, _label), do: other

  defp expect_missing({:error, error} = result) do
    if Error.resource_missing?(error), do: {:recorded_error, error}, else: result
  end

  defp expect_missing({:ok, _deleted}),
    do: {:error, {:exception, %RuntimeError{message: "deleting twice succeeded"}}}

  # The parameters ``Tymeslot.MeetingPayments.CheckoutSessions`` builds for a booking, minus the application fee.
  defp connect_checkout_params(unix) do
    %{
      mode: "payment",
      line_items: [
        %{
          price_data: %{
            currency: "gbp",
            unit_amount: 1000,
            product_data: %{name: "Live suite booking"}
          },
          quantity: 1
        }
      ],
      payment_intent_data: %{metadata: %{host_user_id: 1}},
      invoice_creation: %{enabled: true},
      customer_email: "stripe-live+#{unix}@example.test",
      client_reference_id: "live-#{unix}",
      # Stripe's minimum is 30 minutes from when the call arrives.
      expires_at: System.os_time(:second) + 31 * 60,
      success_url: "https://example.test/paid?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "https://example.test/cancel",
      locale: "en"
    }
  end
end
