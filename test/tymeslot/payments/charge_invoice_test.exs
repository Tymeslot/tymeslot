defmodule Tymeslot.Payments.ChargeInvoiceTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments

  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Payments.ChargeInvoice
  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  defp invoice(id, overrides \\ %{}),
    do: StripeFixtures.object("invoice", Map.put(overrides, "id", id))

  defp invoice_payments(invoice_ids) do
    invoice_ids
    |> Enum.map(&StripeFixtures.object("invoice_payment", %{"invoice" => &1}))
    |> StripeFixtures.list()
  end

  describe "for_charge/1 with a charge that names its invoice" do
    test "a recorded invoice answers without asking Stripe" do
      {:ok, _invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_recorded",
          subscription_id: "sub_recorded"
        })

      assert {:ok, %{invoice_id: "in_recorded", subscription_id: "sub_recorded"}} =
               ChargeInvoice.for_charge(%{"invoice" => "in_recorded"})
    end

    test "an invoice not recorded here is read from Stripe" do
      StripeStub.expect(:retrieve_invoice, invoice("in_old", %{"subscription" => "sub_old"}))

      assert {:ok, %{invoice_id: "in_old", subscription_id: "sub_old"}} =
               ChargeInvoice.for_charge(%{"invoice" => "in_old"})

      assert [%{path: "/v1/invoices/in_old"}] = StripeStub.requests(:retrieve_invoice)
    end

    test "an invoice that billed no subscription names none" do
      StripeStub.expect(:retrieve_invoice, invoice("in_one_off", %{"parent" => nil}))

      assert {:ok, %{invoice_id: "in_one_off", subscription_id: nil}} =
               ChargeInvoice.for_charge(%{"invoice" => "in_one_off"})
    end

    test "a Stripe failure is an error, not a guess" do
      StripeStub.stub(:retrieve_invoice, {:error_fixture, "api_error"})

      assert {:error, {:stripe_lookup_failed, %Error{type: "api_error"}}} =
               ChargeInvoice.for_charge(%{"invoice" => "in_old"})
    end
  end

  describe "for_charge/1 with a charge that does not name its invoice" do
    test "a payment intent that paid no invoice names neither" do
      StripeStub.expect(:list_invoice_payments, invoice_payments([]))

      assert {:ok, %{invoice_id: nil, subscription_id: nil}} =
               ChargeInvoice.for_charge(%{"payment_intent" => "pi_one_off"})
    end

    test "a charge with neither invoice nor payment intent names neither, without Stripe" do
      assert {:ok, %{invoice_id: nil, subscription_id: nil}} =
               ChargeInvoice.for_charge(%{"id" => "ch_bare"})
    end

    test "a Stripe failure is an error" do
      StripeStub.stub(:list_invoice_payments, {:error_fixture, "api_error"})

      assert {:error, {:stripe_lookup_failed, %Error{type: "api_error"}}} =
               ChargeInvoice.for_charge(%{"payment_intent" => "pi_basil"})
    end
  end

  describe "for_charge_id/1" do
    test "resolves a basil invoice's subscription from parent.subscription_details" do
      StripeStub.expect(
        :retrieve_charge,
        StripeFixtures.object("charge", %{"id" => "ch_1", "invoice" => "in_1"})
      )

      StripeStub.expect(
        :retrieve_invoice,
        invoice("in_1", %{
          "subscription" => nil,
          "parent" => %{
            "type" => "subscription_details",
            "subscription_details" => %{"subscription" => "sub_basil"}
          }
        })
      )

      assert {:ok, %{invoice_id: "in_1", subscription_id: "sub_basil"}} =
               ChargeInvoice.for_charge_id("ch_1")

      assert [%{path: "/v1/charges/ch_1"}] = StripeStub.requests(:retrieve_charge)
    end

    test "finds the invoice through the payment intent's invoice payment" do
      charge = StripeFixtures.object("charge", %{"id" => "ch_1", "payment_intent" => "pi_1"})
      refute Map.has_key?(charge, "invoice")

      StripeStub.expect(:retrieve_charge, charge)
      StripeStub.expect(:list_invoice_payments, invoice_payments(["in_pi"]))
      StripeStub.expect(:retrieve_invoice, invoice("in_pi", %{"subscription" => "sub_pi"}))

      assert {:ok, %{invoice_id: "in_pi", subscription_id: "sub_pi"}} =
               ChargeInvoice.for_charge_id("ch_1")

      assert [%{query: query}] = StripeStub.requests(:list_invoice_payments)

      assert query == %{"payment" => %{"type" => "payment_intent", "payment_intent" => "pi_1"}}
    end

    test "an expanded invoice on the invoice payment is read by its id" do
      StripeStub.expect(:retrieve_charge, StripeFixtures.object("charge", %{"id" => "ch_1"}))

      StripeStub.expect(
        :list_invoice_payments,
        StripeFixtures.list([
          StripeFixtures.object("invoice_payment", %{"invoice" => invoice("in_expanded")})
        ])
      )

      StripeStub.expect(:retrieve_invoice, invoice("in_expanded", %{"subscription" => "sub_1"}))

      assert {:ok, %{invoice_id: "in_expanded", subscription_id: "sub_1"}} =
               ChargeInvoice.for_charge_id("ch_1")
    end

    test "a Stripe failure reading the charge is an error" do
      StripeStub.stub(:retrieve_charge, {:error_fixture, "api_error"})

      assert {:error, {:stripe_lookup_failed, %Error{type: "api_error"}}} =
               ChargeInvoice.for_charge_id("ch_1")
    end
  end
end
