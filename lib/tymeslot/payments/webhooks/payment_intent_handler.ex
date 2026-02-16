defmodule Tymeslot.Payments.Webhooks.PaymentIntentHandler do
  @moduledoc """
  Handler for payment_intent webhook events.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type),
    do: event_type in ["payment_intent.succeeded", "payment_intent.created"]

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(_payment_intent) do
    # Trust Stripe's data
    :ok
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(%{type: "payment_intent.succeeded"}, payment_intent) do
    Logger.info("Processing payment_intent.succeeded",
      payment_intent_id: Map.get(payment_intent, "id")
    )

    # Payment intents are intermediate events - the actual payment processing
    # is handled by checkout.session.completed events
    {:ok, :payment_intent_logged}
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(%{type: "payment_intent.created"}, payment_intent) do
    Logger.info("Processing payment_intent.created",
      payment_intent_id: Map.get(payment_intent, "id")
    )

    # Payment intent creation is just a log event
    {:ok, :payment_intent_logged}
  end
end
