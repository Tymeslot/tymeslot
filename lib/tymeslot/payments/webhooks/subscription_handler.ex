defmodule Tymeslot.Payments.Webhooks.SubscriptionHandler do
  @moduledoc """
  Handler for customer.subscription.* webhook events.
  """
  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger
  alias Tymeslot.Payments.Behaviours.WebhookHandler
  alias Tymeslot.Payments.PubSub

  @impl WebhookHandler
  def handle(%{"data" => %{"object" => %{"id" => subscription_id} = subscription}} = event)
      when is_binary(subscription_id) and subscription_id != "" do
    event_type = event["type"]

    Logger.info("Processing subscription event",
      event_type: event_type,
      subscription_id: subscription_id
    )

    # The Stripe event's id and creation time let the receiver deduplicate
    # redeliveries and ignore an event older than one it has already applied.
    case PubSub.hand_off_subscription_event(%{
           event: normalize_event_name(event_type),
           subscription_id: subscription_id,
           subscription_data: subscription,
           event_id: event["id"],
           event_created: event["created"]
         }) do
      :ok -> {:ok, :event_processed}
      {:error, reason} -> {:error, :retry_later, {:hand_off_failed, reason}}
    end
  end

  def handle(_event), do: {:error, :permanent, :missing_subscription_id}

  defp normalize_event_name("customer.subscription.created"), do: :subscription_created
  defp normalize_event_name("customer.subscription.updated"), do: :subscription_updated
  defp normalize_event_name("customer.subscription.deleted"), do: :subscription_deleted
  defp normalize_event_name(_other), do: :subscription_event
end
