defmodule Tymeslot.Payments.ChargeInvoiceTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments

  import Mox

  alias Tymeslot.Payments.ChargeInvoice
  alias Tymeslot.Payments.StripeMock
  alias Tymeslot.Payments.SubscriptionInvoiceQueries

  setup :verify_on_exit!

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
      expect(StripeMock, :get_invoice, fn "in_old" ->
        {:ok, %{id: "in_old", subscription: "sub_old"}}
      end)

      assert {:ok, %{invoice_id: "in_old", subscription_id: "sub_old"}} =
               ChargeInvoice.for_charge(%{"invoice" => "in_old"})
    end

    test "reads the subscription from where newer API versions put it" do
      expect(StripeMock, :get_invoice, fn "in_old" ->
        {:ok,
         %{
           id: "in_old",
           subscription: nil,
           parent: %{subscription_details: %{subscription: "sub_basil"}}
         }}
      end)

      assert {:ok, %{invoice_id: "in_old", subscription_id: "sub_basil"}} =
               ChargeInvoice.for_charge(%{"invoice" => "in_old"})
    end

    test "an invoice that billed no subscription names none" do
      expect(StripeMock, :get_invoice, fn "in_one_off" ->
        {:ok, %{id: "in_one_off", subscription: nil, parent: nil}}
      end)

      assert {:ok, %{invoice_id: "in_one_off", subscription_id: nil}} =
               ChargeInvoice.for_charge(%{"invoice" => "in_one_off"})
    end

    test "a Stripe failure is an error, not a guess" do
      expect(StripeMock, :get_invoice, fn "in_old" -> {:error, :timeout} end)

      assert {:error, {:stripe_lookup_failed, :timeout}} =
               ChargeInvoice.for_charge(%{"invoice" => "in_old"})
    end
  end

  describe "for_charge/1 with a charge that does not name its invoice" do
    test "finds the invoice through the charge's payment intent" do
      expect(StripeMock, :list_invoice_payments, fn params ->
        assert params == %{payment: %{type: "payment_intent", payment_intent: "pi_basil"}}
        {:ok, %{data: [%{invoice: "in_basil"}], has_more: false}}
      end)

      expect(StripeMock, :get_invoice, fn "in_basil" ->
        {:ok, %{id: "in_basil", parent: %{subscription_details: %{subscription: "sub_basil"}}}}
      end)

      assert {:ok, %{invoice_id: "in_basil", subscription_id: "sub_basil"}} =
               ChargeInvoice.for_charge(%{"payment_intent" => "pi_basil"})
    end

    test "a payment intent that paid no invoice names neither" do
      expect(StripeMock, :list_invoice_payments, fn _params ->
        {:ok, %{data: [], has_more: false}}
      end)

      assert {:ok, %{invoice_id: nil, subscription_id: nil}} =
               ChargeInvoice.for_charge(%{"payment_intent" => "pi_one_off"})
    end

    test "a charge with neither invoice nor payment intent names neither, without Stripe" do
      assert {:ok, %{invoice_id: nil, subscription_id: nil}} =
               ChargeInvoice.for_charge(%{"id" => "ch_bare"})
    end

    test "a Stripe failure is an error" do
      expect(StripeMock, :list_invoice_payments, fn _params -> {:error, :timeout} end)

      assert {:error, {:stripe_lookup_failed, :timeout}} =
               ChargeInvoice.for_charge(%{"payment_intent" => "pi_basil"})
    end
  end

  describe "for_charge_id/1" do
    test "reads the charge from Stripe, then its invoice" do
      expect(StripeMock, :get_charge, fn "ch_1" ->
        {:ok, %{id: "ch_1", payment_intent: "pi_1"}}
      end)

      expect(StripeMock, :list_invoice_payments, fn _params ->
        {:ok, %{data: [%{invoice: %{id: "in_1"}}]}}
      end)

      expect(StripeMock, :get_invoice, fn "in_1" ->
        {:ok, %{id: "in_1", subscription: "sub_1"}}
      end)

      assert {:ok, %{invoice_id: "in_1", subscription_id: "sub_1"}} =
               ChargeInvoice.for_charge_id("ch_1")
    end

    test "a Stripe failure reading the charge is an error" do
      expect(StripeMock, :get_charge, fn "ch_1" -> {:error, :timeout} end)

      assert {:error, {:stripe_lookup_failed, :timeout}} = ChargeInvoice.for_charge_id("ch_1")
    end
  end
end
