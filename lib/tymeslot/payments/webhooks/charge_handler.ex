defmodule Tymeslot.Payments.Webhooks.ChargeHandler do
  @moduledoc """
  Handler for charge.succeeded and charge.failed webhook events.
  """

  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type), do: event_type in ["charge.succeeded", "charge.failed"]

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(_charge) do
    # Trust Stripe's data
    :ok
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(%{type: "charge.succeeded"}, charge) do
    Logger.info("Processing charge.succeeded", charge_id: Map.get(charge, "id"))

    # For charge events, we don't process payments since the checkout.session.completed
    # event already handled the payment processing. We just log the charge success.
    Logger.info("Charge succeeded", charge_id: Map.get(charge, "id"))
    {:ok, :charge_logged}
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(%{type: "charge.failed"}, charge) do
    Logger.info("Processing charge.failed", charge_id: Map.get(charge, "id"))

    # For charge events, we just log the failure. The main payment flow
    # should be handled by checkout.session events, not individual charges.
    Logger.warning("Charge failed", charge_id: Map.get(charge, "id"))
    {:ok, :charge_failed_logged}
  end
end
