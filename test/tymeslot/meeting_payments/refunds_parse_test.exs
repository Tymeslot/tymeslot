defmodule Tymeslot.MeetingPayments.RefundsParseTest do
  use ExUnit.Case, async: true

  @moduletag :payments

  alias Tymeslot.MeetingPayments.Refunds

  defp payment_stub(attrs \\ %{}) do
    defaults = %{
      amount_cents: 5000,
      currency: "eur",
      refunded_amount_cents: 0,
      status: "paid",
      paid_at: DateTime.utc_now(:second)
    }

    Map.merge(defaults, Map.new(attrs))
  end

  describe "parse_refund_amount/2" do
    test "full type returns the remaining refundable amount" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 1000})
      assert {:ok, 4000} = Refunds.parse_refund_amount(payment, %{"refund_type" => "full"})
    end

    test "partial type with valid decimal amount returns cents" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 0})

      assert {:ok, 1500} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "15.00"
               })
    end

    test "partial type normalises comma as decimal separator" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 0})

      assert {:ok, 1500} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "15,00"
               })
    end

    test "partial type parses whole-number amount (no decimal point)" do
      payment = payment_stub(%{amount_cents: 10_000, refunded_amount_cents: 0})

      assert {:ok, 1000} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "10"
               })
    end

    test "partial type parses sub-dollar amount correctly" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 0})

      assert {:ok, 50} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "0.50"
               })
    end

    test "partial type parses 29.99 correctly (no float rounding hazard)" do
      payment = payment_stub(%{amount_cents: 10_000, refunded_amount_cents: 0})

      assert {:ok, 2999} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "29.99"
               })
    end

    test "partial type returns :invalid_amount for scientific notation" do
      payment = payment_stub()

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "1e2"
               })
    end

    test "partial type returns :invalid_amount for negative amount" do
      payment = payment_stub()

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "-1"
               })
    end

    test "partial type accepts a single decimal place as tenths" do
      payment = payment_stub()

      assert {:ok, 1050} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "10.5"
               })
    end

    test "partial type rejects more decimals than the currency has" do
      payment = payment_stub()

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "10.505"
               })
    end

    test "partial type counts a zero-decimal currency in whole units" do
      payment = payment_stub(%{currency: "jpy", amount_cents: 5000})

      assert {:ok, 1500} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "1500"
               })

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "1500.5"
               })
    end

    test "partial type returns :invalid_amount for sub-cent precision" do
      payment = payment_stub()

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "10.005"
               })
    end

    test "partial type returns :exceeds_remaining when amount is too large" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 4500})

      assert {:error, :exceeds_remaining} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "10.00"
               })
    end

    test "partial type returns :invalid_amount for zero" do
      payment = payment_stub()

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "0"})
    end

    test "partial type returns :invalid_amount for zero with decimal" do
      payment = payment_stub()

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "0.00"
               })
    end

    test "partial type returns :invalid_amount for non-numeric string" do
      payment = payment_stub()

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{
                 "refund_type" => "partial",
                 "amount" => "abc"
               })
    end

    test "partial type returns :invalid_amount for empty string" do
      payment = payment_stub()

      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => ""})
    end

    test "returns :choose_type when refund_type key is absent" do
      payment = payment_stub()
      assert {:error, :choose_type} = Refunds.parse_refund_amount(payment, %{})
    end

    test "returns :choose_type for an unrecognised refund_type value" do
      payment = payment_stub()

      assert {:error, :choose_type} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "unknown"})
    end
  end
end
