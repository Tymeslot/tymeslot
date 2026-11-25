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

  describe "stripe_refunded_cents/1" do
    test "reads the refunds made, which the capped whole cannot hide" do
      payment = %{
        amount_cents: 10_000,
        refunded_amount_cents: 10_000,
        stripe_refunded_cents: 10_000,
        disputed_lost_cents: 10_000
      }

      assert RefundedTotal.stripe_refunded_cents(payment) == 10_000
    end
  end

  describe "with_stripe_refunded/2" do
    test "raises the refunds to Stripe's total and adds the dispute's part" do
      payment = paid(stripe_refunded_cents: 2_000, disputed_lost_cents: 3_000)

      assert RefundedTotal.with_stripe_refunded(payment, 4_000) == %{
               stripe_refunded_cents: 4_000,
               disputed_lost_cents: 3_000,
               refunded_amount_cents: 7_000,
               status: :partially_refunded
             }
    end

    test "never lowers the refunds already recorded" do
      payment = paid(stripe_refunded_cents: 5_000)

      assert %{stripe_refunded_cents: 5_000, refunded_amount_cents: 5_000} =
               RefundedTotal.with_stripe_refunded(payment, 1_000)
    end

    test "refunds after a full lost dispute keep both figures, the whole at the amount paid" do
      payment = paid(stripe_refunded_cents: 0, disputed_lost_cents: 10_000)

      assert RefundedTotal.with_stripe_refunded(payment, 10_000) == %{
               stripe_refunded_cents: 10_000,
               disputed_lost_cents: 10_000,
               refunded_amount_cents: 10_000,
               status: :refunded
             }
    end
  end

  describe "with_refund_made/3" do
    test "raises the refunds by the refund's amount when Stripe's total holds it" do
      payment = paid(stripe_refunded_cents: 2_000, disputed_lost_cents: 3_000)

      assert RefundedTotal.with_refund_made(payment, 4_000, 2_000) == %{
               stripe_refunded_cents: 4_000,
               disputed_lost_cents: 3_000,
               refunded_amount_cents: 7_000,
               status: :partially_refunded
             }
    end

    test "does not count again a failed refund a stale total still holds" do
      # 3_000 was taken off when it failed; the total was read before that.
      payment = paid(stripe_refunded_cents: 0)

      assert %{stripe_refunded_cents: 2_000, refunded_amount_cents: 2_000} =
               RefundedTotal.with_refund_made(payment, 5_000, 2_000)
    end

    test "does not count twice a refund a recorded total already holds" do
      payment = paid(stripe_refunded_cents: 4_000)

      assert %{stripe_refunded_cents: 4_000} =
               RefundedTotal.with_refund_made(payment, 4_000, 2_000)
    end

    test "never lowers the refunds already recorded" do
      payment = paid(stripe_refunded_cents: 5_000)

      assert %{stripe_refunded_cents: 5_000} =
               RefundedTotal.with_refund_made(payment, 1_000, 1_000)
    end
  end

  describe "with_refund_failed/2" do
    test "with_refund_failed lowers the refunds and keeps the dispute share" do
      payment = paid(stripe_refunded_cents: 5_000, disputed_lost_cents: 2_000)

      assert RefundedTotal.with_refund_failed(payment, 3_000) == %{
               stripe_refunded_cents: 2_000,
               disputed_lost_cents: 2_000,
               refunded_amount_cents: 4_000,
               status: :partially_refunded
             }
    end

    test "never below the dispute share" do
      payment = paid(stripe_refunded_cents: 5_000, disputed_lost_cents: 2_000)

      assert %{stripe_refunded_cents: 0, refunded_amount_cents: 2_000} =
               RefundedTotal.with_refund_failed(payment, 6_000)
    end

    test "a failed refund after a full lost dispute lowers the refunds, not the whole" do
      payment = paid(stripe_refunded_cents: 10_000, disputed_lost_cents: 10_000)

      assert %{stripe_refunded_cents: 4_000, refunded_amount_cents: 10_000} =
               RefundedTotal.with_refund_failed(payment, 6_000)
    end
  end

  describe "with_dispute_lost/2" do
    test "a full refund then a full lost dispute keeps both figures" do
      payment = paid(stripe_refunded_cents: 10_000)

      assert %{
               stripe_refunded_cents: 10_000,
               disputed_lost_cents: 10_000,
               refunded_amount_cents: 10_000
             } = RefundedTotal.with_dispute_lost(payment, 10_000)
    end

    test "the dispute's part is added to the refunds made before it" do
      payment = paid(stripe_refunded_cents: 1_000)

      assert %{
               stripe_refunded_cents: 1_000,
               disputed_lost_cents: 2_000,
               refunded_amount_cents: 3_000
             } = RefundedTotal.with_dispute_lost(payment, 2_000)
    end

    test "a second report of the loss records it once" do
      payment = paid(stripe_refunded_cents: 1_000, disputed_lost_cents: 2_000)

      assert %{disputed_lost_cents: 2_000, refunded_amount_cents: 3_000} =
               RefundedTotal.with_dispute_lost(payment, 2_000)
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

  # A paid payment of 10_000 whose whole is what its two parts give.
  defp paid(attrs) do
    refunds = Keyword.get(attrs, :stripe_refunded_cents, 0)
    lost = Keyword.get(attrs, :disputed_lost_cents, 0)

    %{
      status: :paid,
      amount_cents: 10_000,
      stripe_refunded_cents: refunds,
      disputed_lost_cents: lost,
      refunded_amount_cents: min(refunds + lost, 10_000)
    }
  end
end
