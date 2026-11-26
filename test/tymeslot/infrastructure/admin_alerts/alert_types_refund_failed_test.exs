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

  describe "the alert for a late-payment refund its job could not record" do
    test ":late_payment_refund_failed names the payment, the reason and the job to retry" do
      metadata = %{booking_payment_id: "bp_1", oban_job_id: 7, reason_code: "refund_in_progress"}

      msg = AlertTypes.format_message(:late_payment_refund_failed, metadata)

      assert msg =~ "Refund of booking payment bp_1"
      assert msg =~ "(refund_in_progress)"
      assert msg =~ "still owed"
      assert msg =~ "retry Oban job 7"
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

  describe "the alert for a refund Stripe made twice" do
    test ":refund_duplicated names both Stripe refunds, the amount and the payment" do
      metadata = %{
        refund_id: "rf_1",
        booking_payment_id: "bp_1",
        stripe_refund_id: "re_1",
        duplicate_stripe_refund_id: "re_2",
        duplicate_amount_cents: 2_000
      }

      msg = AlertTypes.format_message(:refund_duplicated, metadata)

      assert msg =~ "second refund, re_2 of 2000 cents, for refund rf_1"
      assert msg =~ "booking payment bp_1, which records re_1"
      assert msg =~ "refunded twice"
    end

    test ":refund_duplicated dedups per duplicate Stripe refund" do
      key =
        &AlertTypes.dedup_key(:refund_duplicated, %{
          refund_id: "rf_1",
          duplicate_stripe_refund_id: &1
        })

      assert key.("re_2") == key.("re_2")
      refute key.("re_2") == key.("re_3")
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
      refute msg =~ "host"
    end

    test ":refund_failure_reversed asks for a host who may have been told to be told" do
      metadata = %{refund_id: "rf_1", host_may_have_been_told: true}

      msg = AlertTypes.format_message(:refund_failure_reversed, metadata)

      assert msg =~ "The host may have been emailed that it failed: tell them it was made"
    end
  end
end
