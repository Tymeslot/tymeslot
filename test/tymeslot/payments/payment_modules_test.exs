defmodule Tymeslot.Payments.PaymentModulesTest do
  @moduletag :payments
  # PubSub tests need sequential execution
  @moduletag :payments
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Payments.{ErrorHandler, PubSub}
  alias Tymeslot.Payments.Errors.WebhookError.ProcessingError
  alias Tymeslot.Payments.Errors.WebhookError.SignatureError
  alias Tymeslot.Payments.Errors.WebhookError.ValidationError

  describe "ErrorHandler" do
    test "handle_payment_error returns :ok" do
      assert {:ok, :error_handled} =
               ErrorHandler.handle_payment_error("stripe_123", "some error", 1)
    end

    test "handle_subscription_error returns :ok" do
      assert {:ok, :error_handled} =
               ErrorHandler.handle_subscription_error("sub_123", "some error", 1)
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

    test "broadcast_payment_successful broadcasts to topic", %{pubsub_server: pubsub_server} do
      Phoenix.PubSub.subscribe(pubsub_server, "payment:payment_successful")

      transaction = %{user_id: 1, id: 123}
      PubSub.broadcast_payment_successful(transaction)

      assert_receive {:payment_successful, %{user_id: 1, transaction: ^transaction}}
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
    end

    test "ProcessingError can be created" do
      error = %ProcessingError{message: "test", reason: :failed}
      assert error.message == "test"
    end
  end
end
