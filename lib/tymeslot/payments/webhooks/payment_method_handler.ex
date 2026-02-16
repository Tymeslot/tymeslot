defmodule Tymeslot.Payments.Webhooks.PaymentMethodHandler do
  @moduledoc """
  Handler for payment_method.* webhook events.
  """
  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type), do: event_type == "payment_method.attached"

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(payment_method) do
    case Map.get(payment_method, "id") do
      nil -> {:error, :missing_field, "Payment method ID missing"}
      "" -> {:error, :missing_field, "Payment method ID empty"}
      _id -> :ok
    end
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(event, payment_method) do
    event_type = event["type"] || event[:type]
    payment_method_id = payment_method["id"]
    customer_id = payment_method["customer"]

    Logger.info("Processing payment_method event",
      event_type: event_type,
      payment_method_id: payment_method_id,
      customer_id: customer_id
    )

    {:ok, :payment_method_processed}
  end
end
