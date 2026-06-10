defmodule Tymeslot.MeetingPayments.StripeAdapterTest do
  use ExUnit.Case, async: true

  import Mox

  @moduletag :payments
  @moduletag :unit

  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  setup :verify_on_exit!

  test "create_account/2 delegates to configured impl" do
    expect(StripeAdapterMock, :create_account, fn _params, _opts ->
      {:ok, %{id: "acct_TEST"}}
    end)

    assert {:ok, %{id: "acct_TEST"}} =
             StripeAdapter.create_account(%{type: "standard"}, idempotency_key: "k")
  end

  test "create_checkout_session/2 delegates with opts" do
    expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
      assert params.mode == "payment"
      assert opts[:connect_account] == "acct_HOST"
      {:ok, %{id: "cs_TEST", url: "https://checkout.stripe.com/cs_TEST"}}
    end)

    assert {:ok, %{id: "cs_TEST"}} =
             StripeAdapter.create_checkout_session(
               %{mode: "payment"},
               connect_account: "acct_HOST"
             )
  end

  test "create_refund/2 delegates with idempotency_key" do
    expect(StripeAdapterMock, :create_refund, fn params, opts ->
      assert params.amount == 5000
      assert opts[:idempotency_key] == "refund:test:5000:5000"
      {:ok, %{id: "re_TEST"}}
    end)

    assert {:ok, %{id: "re_TEST"}} =
             StripeAdapter.create_refund(
               %{charge: "ch_x", amount: 5000},
               idempotency_key: "refund:test:5000:5000"
             )
  end

  test "retrieve_charge/2 normalises the response to a string-keyed map" do
    expect(StripeAdapterMock, :retrieve_charge, fn _id, _opts ->
      {:ok, %{id: "ch_TEST", receipt_url: "https://pay.stripe.com/r/x"}}
    end)

    assert {:ok, %{"id" => "ch_TEST", "receipt_url" => "https://pay.stripe.com/r/x"}} =
             StripeAdapter.retrieve_charge("ch_TEST", connect_account: "acct_HOST")
  end

  test "retrieve_account/1 normalises a stripity struct to a deep string-keyed map" do
    # The production adapter hands back an atom-keyed %Stripe.Account{} whose
    # nested requirements object is a map. The seam must flatten both the struct
    # and the nested map so workers and apply_account_event see uniform string
    # keys throughout.
    expect(StripeAdapterMock, :retrieve_account, fn _id ->
      {:ok,
       %Stripe.Account{
         id: "acct_STRUCT",
         charges_enabled: true,
         payouts_enabled: true,
         details_submitted: true,
         requirements: %{disabled_reason: "rejected.fraud"}
       }}
    end)

    assert {:ok, account} = StripeAdapter.retrieve_account("acct_STRUCT")
    assert account["id"] == "acct_STRUCT"
    assert account["charges_enabled"] == true
    assert account["requirements"]["disabled_reason"] == "rejected.fraud"
  end

  test "retrieve_checkout_session/2 normalises a stripity struct to a string-keyed map" do
    expect(StripeAdapterMock, :retrieve_checkout_session, fn _id, _opts ->
      {:ok,
       %Stripe.Checkout.Session{
         id: "cs_STRUCT",
         payment_status: "paid",
         status: "complete",
         client_reference_id: "meeting-1",
         payment_intent: "pi_STRUCT"
       }}
    end)

    assert {:ok, session} = StripeAdapter.retrieve_checkout_session("cs_STRUCT", [])
    assert session["payment_status"] == "paid"
    assert session["client_reference_id"] == "meeting-1"
    assert session["payment_intent"] == "pi_STRUCT"
  end

  test "retrieve_charge/2 passes Stripe errors through untouched" do
    expect(StripeAdapterMock, :retrieve_charge, fn _id, _opts -> {:error, :api_error} end)

    assert {:error, :api_error} =
             StripeAdapter.retrieve_charge("ch_TEST", connect_account: "acct_HOST")
  end
end
