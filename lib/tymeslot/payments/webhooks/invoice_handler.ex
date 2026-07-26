defmodule Tymeslot.Payments.Webhooks.InvoiceHandler do
  @moduledoc """
  Handler for invoice.* webhook events.
  """
  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger
  alias Tymeslot.Payments.DatabaseOperations

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type) do
    event_type in [
      "invoice.created",
      "invoice.finalized",
      "invoice.paid",
      "invoice.payment_succeeded",
      "invoice.payment_failed",
      "invoice.upcoming"
    ]
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(invoice), do: validate(nil, invoice)

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(event_type, invoice) do
    case Map.get(invoice, "id") do
      nil when event_type == "invoice.upcoming" ->
        :ok

      nil ->
        {:error, :missing_field, "Invoice ID missing"}

      "" ->
        {:error, :missing_field, "Invoice ID empty"}

      _id ->
        :ok
    end
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(event, invoice) do
    event_type = event_type(event)
    subscription_id = subscription_id(invoice)

    Logger.info("Processing invoice event",
      event_type: event_type,
      subscription_id: subscription_id
    )

    case event_type do
      "invoice.payment_succeeded" ->
        handle_payment_succeeded(subscription_id, invoice)

      "invoice.paid" ->
        handle_payment_succeeded(subscription_id, invoice)

      "invoice.payment_failed" ->
        handle_payment_failed(subscription_id, invoice)

      "invoice.created" ->
        {:ok, :invoice_created}

      "invoice.finalized" ->
        {:ok, :invoice_finalized}

      "invoice.upcoming" ->
        {:ok, :invoice_upcoming}

      _other ->
        {:ok, :ignored}
    end
  end

  # Stripe events arrive JSON-decoded, so string-keyed; the webhook processor
  # additionally stamps an atom `:type` before dispatching. Read both here, once.
  defp event_type(event), do: Map.get(event, "type") || Map.get(event, :type)

  # Stripe API 2025-03-31.basil moved the invoice's subscription reference
  # from the top-level field into parent.subscription_details. Read whichever
  # is present; either may hold an id string or an expanded subscription
  # object.
  defp subscription_id(invoice) do
    case invoice["subscription"] ||
           get_in(invoice, ["parent", "subscription_details", "subscription"]) do
      %{"id" => id} -> id
      id -> id
    end
  end

  defp handle_payment_succeeded(nil, _invoice), do: {:ok, :no_subscription}

  defp handle_payment_succeeded(subscription_id, invoice) do
    invoice_id = Map.get(invoice, "id") || Map.get(invoice, :id)

    if is_nil(invoice_id) do
      handle_subscription_renewal(subscription_id, invoice)
    else
      case DatabaseOperations.get_transaction_by_stripe_id(invoice_id) do
        {:ok, _transaction} ->
          {:ok, :already_processed}

        {:error, :transaction_not_found} ->
          handle_subscription_renewal(subscription_id, invoice)
      end
    end
  end

  defp handle_subscription_renewal(subscription_id, invoice) do
    case DatabaseOperations.process_subscription_renewal(subscription_id, invoice) do
      {:ok, :already_processed} ->
        {:ok, :already_processed}

      {:ok, _result} ->
        {:ok, :invoice_processed}

      {:error, :subscription_not_found} ->
        Logger.warning("Subscription not found for invoice, might be a race condition",
          subscription_id: subscription_id
        )

        {:error, :retry_later,
         "Subscription not found for #{subscription_id}, retrying via Stripe"}

      {:error, reason} ->
        Logger.error("Failed to process invoice success",
          subscription_id: subscription_id,
          error: inspect(reason)
        )

        {:error, :processing_failed, "Failed to process invoice success: #{inspect(reason)}"}
    end
  end

  defp handle_payment_failed(nil, _invoice), do: {:ok, :no_subscription}

  defp handle_payment_failed(subscription_id, invoice) do
    case DatabaseOperations.process_subscription_failure(subscription_id, invoice) do
      {:ok, _result} ->
        {:ok, :invoice_processed}

      {:error, :subscription_not_found} ->
        Logger.warning("Subscription not found for invoice failure, might be a race condition",
          subscription_id: subscription_id
        )

        {:error, :retry_later,
         "Subscription not found for #{subscription_id}, retrying via Stripe"}

      {:error, reason} ->
        Logger.error("Failed to process invoice failure",
          subscription_id: subscription_id,
          error: inspect(reason)
        )

        {:error, :processing_failed, "Failed to process invoice failure: #{inspect(reason)}"}
    end
  end
end
