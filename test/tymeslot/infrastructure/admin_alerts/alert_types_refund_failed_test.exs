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
end
