defmodule Tymeslot.Payments.SubscriptionNotifications do
  @moduledoc """
  The single place that logs and broadcasts a subscription payment being
  processed, so the first-payment path
  (`DatabaseOperations.update_transaction_for_subscription/4`, driven by
  `checkout.session.completed`) and the renewal path
  (`Webhooks.InvoiceHandler`, driven by `invoice.paid` /
  `invoice.payment_succeeded`) cannot drift apart.
  """

  require Logger

  alias Tymeslot.Payments.PubSub

  @doc """
  Logs and broadcasts that a subscription payment has been processed.
  """
  @spec processed(struct()) :: :subscription_processed
  def processed(transaction) do
    Logger.info("Subscription updates processed", stripe_id: transaction.stripe_id)

    # Broadcast subscription success event for apps to handle their own business logic
    PubSub.broadcast_subscription_successful(transaction)

    :subscription_processed
  end
end
