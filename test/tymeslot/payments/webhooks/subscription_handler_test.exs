defmodule Tymeslot.Payments.Webhooks.SubscriptionHandlerTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  alias Ecto.Adapters.SQL.Sandbox
  alias Phoenix.PubSub
  alias Phoenix.PubSub.Supervisor
  alias Tymeslot.Payments.Webhooks.SubscriptionHandler
  alias TymeslotSaas.Payments.PaymentEventListener

  setup do
    # Ensure Tymeslot.PubSub is started
    unless Process.whereis(Tymeslot.PubSub) do
      Supervisor.start_link(name: Tymeslot.PubSub, adapter: Phoenix.PubSub.PG2)
    end

    # Allow the PaymentEventListener to access the database connection
    if pid = Process.whereis(PaymentEventListener) do
      Sandbox.allow(Tymeslot.Repo, self(), pid)
    end

    :ok
  end

  describe "can_handle?/1" do
    test "returns true for supported subscription events" do
      assert SubscriptionHandler.can_handle?("customer.subscription.created")
      assert SubscriptionHandler.can_handle?("customer.subscription.updated")
      assert SubscriptionHandler.can_handle?("customer.subscription.deleted")
    end

    test "returns false for unsupported events" do
      refute SubscriptionHandler.can_handle?("customer.created")
    end
  end

  describe "validate/1" do
    test "returns :ok for valid subscription" do
      assert SubscriptionHandler.validate(%{"id" => "sub_123"}) == :ok
    end

    test "returns error for missing or empty id" do
      assert {:error, :missing_field, _reason} = SubscriptionHandler.validate(%{})
      assert {:error, :missing_field, _reason} = SubscriptionHandler.validate(%{"id" => ""})
    end
  end

  describe "process/2" do
    test "broadcasts subscription events" do
      # Subscribe to the topic
      PubSub.subscribe(Tymeslot.PubSub, "payment_events:tymeslot")

      subscription = %{"id" => "sub_123", "status" => "active"}
      event = %{type: "customer.subscription.created"}

      assert {:ok, :event_processed} = SubscriptionHandler.process(event, subscription)

      assert_receive %{
        event: :subscription_created,
        subscription_id: "sub_123",
        subscription_data: ^subscription
      }
    end

    test "handles unknown subscription events with generic name" do
      PubSub.subscribe(Tymeslot.PubSub, "payment_events:tymeslot")

      subscription = %{"id" => "sub_123"}
      event = %{type: "customer.subscription.something_else"}

      assert {:ok, :event_processed} = SubscriptionHandler.process(event, subscription)

      assert_receive %{
        event: :subscription_event,
        subscription_id: "sub_123"
      }
    end
  end
end
