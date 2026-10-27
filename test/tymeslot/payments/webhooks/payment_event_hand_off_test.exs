defmodule Tymeslot.Payments.Webhooks.PaymentEventHandOffTest do
  @moduledoc """
  The durable hand-off of payment events to the configured
  `:payment_event_handler`. Core answers Stripe only after the handler has
  taken the event, and a handler failure fails the delivery so Stripe sends
  it again.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :webhooks

  alias Tymeslot.Payments.PubSub

  alias Tymeslot.Payments.Webhooks.{
    Idempotency,
    IdempotencyCache,
    SubscriptionHandler,
    TrialWillEndHandler
  }

  defmodule RecordingHandler do
    @spec handle_payment_event(map()) :: :ok
    def handle_payment_event(event) do
      send(Application.fetch_env!(:tymeslot, :hand_off_test_pid), {:handed_off, event})
      :ok
    end
  end

  defmodule FailingHandler do
    @spec handle_payment_event(map()) :: {:error, term()}
    def handle_payment_event(_event), do: {:error, :enqueue_failed}
  end

  setup do
    original = Application.get_env(:tymeslot, :payment_event_handler)
    Application.put_env(:tymeslot, :hand_off_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:tymeslot, :hand_off_test_pid)

      if original,
        do: Application.put_env(:tymeslot, :payment_event_handler, original),
        else: Application.delete_env(:tymeslot, :payment_event_handler)
    end)

    :ok
  end

  defp subscription_updated_event(id) do
    %{
      "id" => id,
      "type" => "customer.subscription.updated",
      "data" => %{"object" => %{"id" => "sub_hand_off", "status" => "active"}}
    }
  end

  describe "with a handler configured" do
    test "the handler receives a webhook's subscription event" do
      Application.put_env(:tymeslot, :payment_event_handler, RecordingHandler)

      assert {:ok, :event_processed} =
               SubscriptionHandler.handle(subscription_updated_event("evt_hand_off"))

      assert_received {:handed_off,
                       %{event: :subscription_updated, subscription_id: "sub_hand_off"}}
    end

    test "a handler failure fails the delivery, so Stripe redelivers it" do
      Application.put_env(:tymeslot, :payment_event_handler, FailingHandler)

      event_id = "evt_hand_off_fails_#{System.unique_integer([:positive])}"

      assert {:error, :retry_later} =
               Idempotency.with_idempotency(
                 event_id,
                 "customer.subscription.updated",
                 fn -> SubscriptionHandler.handle(subscription_updated_event(event_id)) end
               )

      # Released rather than settled, so Stripe's redelivery is taken up.
      assert IdempotencyCache.reserve(event_id) == {:ok, :reserved}
    end

    test "a trial-ending event the handler could not take fails the delivery" do
      Application.put_env(:tymeslot, :payment_event_handler, FailingHandler)

      trial_end = DateTime.to_unix(DateTime.add(DateTime.utc_now(), 3, :day))
      subscription = %{"id" => "sub_trial_fails", "customer" => "cus_1", "trial_end" => trial_end}

      event = %{
        "id" => "evt_trial_fails",
        "type" => "customer.subscription.trial_will_end",
        "data" => %{"object" => subscription}
      }

      assert {:error, :retry_later, {:hand_off_failed, :enqueue_failed}} =
               TrialWillEndHandler.handle(event)
    end

    test "a dispute, refund or trial event is handed off with its Stripe event id" do
      Application.put_env(:tymeslot, :payment_event_handler, RecordingHandler)

      assert :ok = PubSub.hand_off_payment_event(:trial_will_end, %{event_id: "evt_trial"})

      assert_received {:handed_off, %{event: :trial_will_end, data: %{event_id: "evt_trial"}}}
    end
  end

  describe "without a handler" do
    test "the event is accepted and goes nowhere" do
      Application.delete_env(:tymeslot, :payment_event_handler)

      assert :ok = PubSub.hand_off_payment_event(:trial_will_end, %{event_id: "evt_plain"})

      refute_received {:handed_off, _event}
    end
  end
end
