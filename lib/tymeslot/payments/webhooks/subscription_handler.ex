defmodule Tymeslot.Payments.Webhooks.SubscriptionHandler do
  @moduledoc """
  Handler for customer.subscription.* webhook events.
  """
  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger
  alias Tymeslot.Payments.PubSub

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type) do
    event_type in [
      "customer.subscription.created",
      "customer.subscription.updated",
      "customer.subscription.deleted"
    ]
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(subscription) do
    validate_id(subscription)
  end

  defp validate_id(subscription) do
    case Map.get(subscription, "id") do
      nil -> {:error, :missing_field, "Subscription ID missing"}
      "" -> {:error, :missing_field, "Subscription ID empty"}
      _id -> :ok
    end
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(event, subscription) do
    event_type = event["type"] || event[:type]
    subscription_id = subscription["id"]

    Logger.info("Processing subscription event",
      event_type: event_type,
      subscription_id: subscription_id
    )

    # Broadcast event for apps to handle
    topic = "payment_events:tymeslot"

    PubSub.broadcast(topic, %{
      event: normalize_event_name(event_type),
      subscription_id: subscription_id,
      subscription_data: subscription
    })

    {:ok, :event_processed}
  end

  defp normalize_event_name("customer.subscription.created"), do: :subscription_created
  defp normalize_event_name("customer.subscription.updated"), do: :subscription_updated
  defp normalize_event_name("customer.subscription.deleted"), do: :subscription_deleted
  defp normalize_event_name(_other), do: :subscription_event
end
