defmodule Tymeslot.Payments.PaymentModulesTest do
  # PubSub tests need sequential execution
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  import Tymeslot.Test.PaymentEventCapture
  alias Tymeslot.Payments.{ErrorHandler, PubSub}
  alias Tymeslot.Test.LogCapture

  describe "ErrorHandler" do
    setup do
      LogCapture.attach()
      :ok
    end

    test "handle_payment_error logs the stripe id, user and error at :error level" do
      assert {:ok, :error_handled} =
               ErrorHandler.handle_payment_error("stripe_123", :card_declined, 1)

      assert_receive {:captured_log,
                      %{
                        level: :error,
                        msg: {:string, message},
                        meta: %{stripe_id: _stripe_id} = meta
                      }}

      assert IO.iodata_to_binary(message) == "Payment error"
      assert meta.stripe_id == "stripe_123"
      assert meta.user_id == 1
      assert meta.error == ":card_declined"
    end

    test "handle_subscription_error logs the subscription id, user and error at :error level" do
      assert {:ok, :error_handled} =
               ErrorHandler.handle_subscription_error("sub_123", :payment_failed, 1)

      assert_receive {:captured_log,
                      %{
                        level: :error,
                        msg: {:string, message},
                        meta: %{subscription_id: _subscription_id} = meta
                      }}

      assert IO.iodata_to_binary(message) == "Subscription error"
      assert meta.subscription_id == "sub_123"
      assert meta.user_id == 1
      assert meta.error == ":payment_failed"
    end
  end

  describe "PubSub" do
    setup :capture_payment_events

    test "hand_off_payment_event hands the event to the payment-event handler" do
      assert :ok =
               PubSub.hand_off_payment_event(:charge_succeeded, %{
                 charge_id: "ch_123",
                 user_id: 42
               })

      assert_received %{event: :charge_succeeded, data: %{charge_id: "ch_123", user_id: 42}}
    end
  end
end
