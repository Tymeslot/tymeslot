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
end
