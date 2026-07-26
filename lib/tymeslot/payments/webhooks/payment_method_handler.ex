defmodule Tymeslot.Payments.Webhooks.PaymentMethodHandler do
  @moduledoc """
  Handler for payment_method.* webhook events.
  """
  use Tymeslot.Payments.Behaviours.WebhookHandler

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
    payment_method_id = payment_method["id"]
    customer_id = payment_method["customer"]

    Logger.info("Processing payment_method event",
      event_type: event_type(event),
      payment_method_id: payment_method_id,
      customer_id: customer_id
    )

    {:ok, :payment_method_processed}
  end

  # Stripe delivers string-keyed payloads; in-process replays and tests hand
  # over atom-keyed ones. Both shapes are answered here so the rest of the
  # module reads a plain string.
  defp event_type(%{"type" => type}) when is_binary(type), do: type
  defp event_type(%{type: type}) when is_binary(type), do: type
  defp event_type(_event), do: nil
end
