defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypesRefundFailedTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :payments

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  describe "the alert for a recorded refund that failed" do
    test ":refund_failed names the refund, its source, the payment and the code" do
      metadata = %{
        refund_id: "rf_1",
        source: :cancellation,
        booking_payment_id: "bp_1",
        failure_code: "charge_already_refunded"
      }

      msg = AlertTypes.format_message(:refund_failed, metadata)

      assert msg =~ "Refund rf_1 (cancellation) of booking payment bp_1"
      assert msg =~ "failed: charge_already_refunded"
      assert msg =~ "still owed"
    end

    test ":refund_failed dedups per refund" do
      key = &AlertTypes.dedup_key(:refund_failed, %{refund_id: &1, booking_payment_id: "bp_1"})

      assert key.("rf_A") == key.("rf_A")
      refute key.("rf_A") == key.("rf_B")
    end
  end

  describe "the alert for a refund its job could not settle" do
    test ":refund_stuck names the refund, its source, the payment and its attempts" do
      metadata = %{refund_id: "rf_1", source: :host, booking_payment_id: "bp_1", attempt: 9}

      msg = AlertTypes.format_message(:refund_stuck, metadata)

      assert msg =~ "Refund rf_1 (host) of booking payment bp_1"
      assert msg =~ "still pending after 9 attempts"
    end

    test ":refund_stuck names the way to record what Stripe did" do
      msg = AlertTypes.format_message(:refund_stuck, %{refund_id: "rf_1"})

      assert msg =~ ~s|Tymeslot.Release.settle_stuck_refund("rf_1", |
    end
  end

  describe "the alert for a failed refund made after all" do
    test ":refund_failure_reversed voids the failure alert and names the refund made" do
      metadata = %{
        refund_id: "rf_1",
        booking_payment_id: "bp_1",
        stripe_refund_id: "re_1",
        failure_code: "retries_exhausted"
      }

      msg = AlertTypes.format_message(:refund_failure_reversed, metadata)

      assert msg =~ "Refund rf_1 of booking payment bp_1"
      assert msg =~ "(retries_exhausted)"
      assert msg =~ "as re_1"
      assert msg =~ "earlier failure alert is void"
    end
  end
end
