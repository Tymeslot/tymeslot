defmodule Tymeslot.Payments.PaymentModulesTest do
  # PubSub tests need sequential execution
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  alias Tymeslot.Payments.{ErrorHandler, PubSub}
  alias Tymeslot.Payments.Errors.WebhookError.ProcessingError
  alias Tymeslot.Payments.Errors.WebhookError.SignatureError
  alias Tymeslot.Payments.Errors.WebhookError.ValidationError
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
    setup do
      # Ensure we use the app PubSub in tests
      Application.put_env(:tymeslot, :test_mode, true)
      pubsub_server = PubSub.get_pubsub_server()
      assert pubsub_server == Tymeslot.PubSub

      {:ok, pubsub_server: pubsub_server}
    end

    test "broadcast_subscription_successful broadcasts to topic", %{pubsub_server: pubsub_server} do
      Phoenix.PubSub.subscribe(pubsub_server, "payment:subscription_successful")

      transaction = %{user_id: 1, subscription_id: "sub_1", id: 123}
      PubSub.broadcast_subscription_successful(transaction)

      assert_receive {:subscription_successful,
                      %{user_id: 1, subscription_id: "sub_1", transaction: ^transaction}}
    end

    test "broadcast_subscription_failed broadcasts to topic", %{pubsub_server: pubsub_server} do
      Phoenix.PubSub.subscribe(pubsub_server, "payment:subscription_failed")

      transaction = %{user_id: 1, subscription_id: "sub_1", id: 123}
      PubSub.broadcast_subscription_failed(transaction)

      assert_receive {:subscription_failed,
                      %{user_id: 1, subscription_id: "sub_1", transaction: ^transaction}}
    end

    test "broadcast_subscription_event broadcasts to topic", %{pubsub_server: pubsub_server} do
      Phoenix.PubSub.subscribe(pubsub_server, "payment_events:tymeslot")

      event_data = %{event: "sub_created", user_id: 1}
      PubSub.broadcast_subscription_event(event_data)

      assert_receive ^event_data
    end

    test "broadcast_payment_event broadcasts to payment_events topic", %{
      pubsub_server: pubsub_server
    } do
      Phoenix.PubSub.subscribe(pubsub_server, "payment_events:tymeslot")

      PubSub.broadcast_payment_event(:charge_succeeded, %{charge_id: "ch_123", user_id: 42})

      assert_receive %{event: :charge_succeeded, data: %{charge_id: "ch_123", user_id: 42}}
    end

    test "get_pubsub_server returns Tymeslot.PubSub in test mode" do
      assert PubSub.get_pubsub_server() == Tymeslot.PubSub
    end
  end

  describe "WebhookError" do
    test "SignatureError can be created" do
      error = %SignatureError{message: "test", reason: :invalid}
      assert error.message == "test"
      assert SignatureError.message(error) == "test"
    end

    test "ValidationError can be created" do
      error = %ValidationError{message: "test", reason: :invalid}
      assert error.message == "test"
      assert ValidationError.message(error) == "test"
    end

    test "ProcessingError can be created" do
      error = %ProcessingError{message: "test", reason: :failed}
      assert error.message == "test"
      assert ProcessingError.message(error) == "test"
    end
  end
end
