defmodule Tymeslot.MeetingPayments.RefundedTotalTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :payments

  alias Tymeslot.MeetingPayments.RefundedTotal

  describe "refundable_cents/2" do
    test "refundable_cents subtracts refunds, the dispute share once, and pending refunds" do
      payment = %{amount_cents: 10_000, refunded_amount_cents: 6_000, disputed_lost_cents: 4_000}

      assert RefundedTotal.refundable_cents(payment, 1_000) == 3_000
    end

    test "never below zero" do
      payment = %{amount_cents: 5_000, refunded_amount_cents: 4_000, disputed_lost_cents: 0}

      assert RefundedTotal.refundable_cents(payment, 2_000) == 0
    end
  end

  describe "with_refund_failed/2" do
    test "with_refund_failed lowers the refunds and keeps the dispute share" do
      payment = %{amount_cents: 10_000, refunded_amount_cents: 7_000, disputed_lost_cents: 2_000}

      assert RefundedTotal.with_refund_failed(payment, 3_000) == 4_000
    end

    test "never below the dispute share" do
      payment = %{amount_cents: 10_000, refunded_amount_cents: 7_000, disputed_lost_cents: 2_000}

      assert RefundedTotal.with_refund_failed(payment, 6_000) == 2_000
    end
  end

  describe "status_for/2" do
    test "follows the total, back to paid once nothing is refunded" do
      payment = %{status: :refunded, amount_cents: 5_000}

      assert RefundedTotal.status_for(payment, 5_000) == :refunded
      assert RefundedTotal.status_for(payment, 1_000) == :partially_refunded
      assert RefundedTotal.status_for(payment, 0) == :paid
    end

    test "a disputed payment stays disputed" do
      assert RefundedTotal.status_for(%{status: :disputed, amount_cents: 5_000}, 0) == :disputed
    end
  end
end
