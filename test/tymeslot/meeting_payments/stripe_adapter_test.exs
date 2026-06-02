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

  test "retrieve_charge/2 delegates" do
    expect(StripeAdapterMock, :retrieve_charge, fn _id, _opts ->
      {:ok, %{id: "ch_TEST", receipt_url: "https://pay.stripe.com/r/x"}}
    end)

    assert {:ok, %{receipt_url: _url}} =
             StripeAdapter.retrieve_charge("ch_TEST", connect_account: "acct_HOST")
  end
end
