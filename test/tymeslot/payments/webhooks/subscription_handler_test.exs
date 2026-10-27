defmodule Tymeslot.Payments.Webhooks.SubscriptionHandlerTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  import Tymeslot.Test.PaymentEventCapture

  alias Tymeslot.Payments.Webhooks.SubscriptionHandler

  defp event(type, object, extra \\ %{}),
    do: Map.merge(%{"type" => type, "data" => %{"object" => object}}, extra)

  describe "a malformed subscription" do
    test "without an id is a permanent failure and hands nothing off" do
      capture_payment_events()

      assert {:error, :permanent, :missing_subscription_id} =
               SubscriptionHandler.handle(event("customer.subscription.created", %{}))

      assert {:error, :permanent, :missing_subscription_id} =
               SubscriptionHandler.handle(event("customer.subscription.created", %{"id" => ""}))

      refute_receive %{event: _event}, 50
    end
  end

  describe "handle/1" do
    test "hands off subscription events" do
      capture_payment_events()

      subscription = %{"id" => "sub_123", "status" => "active"}
      event = event("customer.subscription.created", subscription)

      assert {:ok, :event_processed} = SubscriptionHandler.handle(event)

      assert_receive %{
        event: :subscription_created,
        subscription_id: "sub_123",
        subscription_data: ^subscription
      }
    end

    # The receiver orders events by Stripe's creation time and deduplicates
    # them by id, so both must travel with the subscription.
    test "carries the Stripe event's id and creation time" do
      capture_payment_events()

      subscription = %{"id" => "sub_ordered", "status" => "active"}

      event =
        event("customer.subscription.updated", subscription, %{
          "id" => "evt_ordered",
          "created" => 1_700_000_123
        })

      assert {:ok, :event_processed} = SubscriptionHandler.handle(event)

      assert_receive %{
        subscription_id: "sub_ordered",
        event_id: "evt_ordered",
        event_created: 1_700_000_123
      }
    end

    test "handles unknown subscription events with generic name" do
      capture_payment_events()

      subscription = %{"id" => "sub_123"}
      event = event("customer.subscription.something_else", subscription)

      assert {:ok, :event_processed} = SubscriptionHandler.handle(event)

      assert_receive %{
        event: :subscription_event,
        subscription_id: "sub_123"
      }
    end
  end
end
