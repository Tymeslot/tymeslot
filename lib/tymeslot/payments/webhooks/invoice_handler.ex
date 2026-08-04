defmodule Tymeslot.Payments.Webhooks.InvoiceHandler do
  @moduledoc """
  Handler for invoice.* webhook events.
  """
  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger
  alias Tymeslot.Payments.ChangesetHelpers
  alias Tymeslot.Payments.DatabaseOperations
  alias Tymeslot.Payments.SubscriptionInvoices
  alias Tymeslot.Payments.SubscriptionNotifications
  alias Tymeslot.Payments.Webhooks.InvoiceEvent

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type) do
    event_type in [
      "invoice.created",
      "invoice.finalized",
      "invoice.paid",
      "invoice.payment_succeeded",
      "invoice.payment_failed",
      "invoice.upcoming",
      "invoice.voided",
      "invoice.marked_uncollectible"
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
    # WebhookProcessor stamps an atom :type on every event before dispatch.
    event_type = Map.get(event, :type)
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
        capture_document(subscription_id, invoice, :invoice_finalized)

      "invoice.voided" ->
        capture_document(subscription_id, invoice, :invoice_voided)

      "invoice.marked_uncollectible" ->
        capture_document(subscription_id, invoice, :invoice_uncollectible)

      "invoice.upcoming" ->
        {:ok, :invoice_upcoming}

      _other ->
        {:ok, :ignored}
    end
  end

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
    event = InvoiceEvent.from_payload(invoice, subscription_id)

    case SubscriptionInvoices.coordinate_renewal(event) do
      {:ok, :already_processed} ->
        capture_document(event, :already_processed)

      {:ok, transaction} ->
        SubscriptionNotifications.processed(transaction)
        capture_document(event, :invoice_processed)

      {:error, :subscription_not_found} ->
        Logger.warning("Subscription not found for invoice, might be a race condition",
          subscription_id: subscription_id
        )

        {:error, :retry_later,
         "Subscription not found for #{subscription_id}, retrying via Stripe"}

      {:error, reason} ->
        Logger.error("Failed to process invoice success",
          subscription_id: subscription_id,
          error: error_summary(reason)
        )

        {:error, :processing_failed, "Failed to process invoice success for #{subscription_id}"}
    end
  end

  # Stripe finalises an invoice before charging it, and a subscription's first
  # invoice is recorded against the checkout session rather than the invoice,
  # so the transaction may not exist when the event lands. A missing
  # opportunistic link is never a failure: capture/1 is a plain upsert keyed
  # on the invoice's own id, independent of any transaction row.
  defp capture_document(subscription_id, invoice, result) do
    invoice
    |> InvoiceEvent.from_payload(subscription_id)
    |> capture_document(result)
  end

  defp capture_document(%InvoiceEvent{} = event, result) do
    case SubscriptionInvoices.capture(event) do
      {:ok, _invoice} ->
        {:ok, result}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_capture_failure(changeset, event, result)
    end
  end

  # A DB-constraint failure (unique/foreign key/check) reflects a transient
  # condition — most likely a race with a concurrent delivery of the same or
  # a related event — so it is worth Stripe redelivering. A plain validation
  # failure (a required field, or an invoice status Stripe sent that this
  # schema's Ecto.Enum doesn't recognise) is deterministic: the same payload
  # would fail identically next time, so redelivery would only retry forever
  # and is logged and swallowed instead.
  defp handle_capture_failure(%Ecto.Changeset{} = changeset, event, result) do
    if ChangesetHelpers.constraint_violation?(changeset) do
      Logger.warning("Failed to capture invoice document, retrying via Stripe",
        subscription_id: event.subscription_id,
        stripe_invoice_id: event.id,
        error: error_summary(changeset)
      )

      {:error, :retry_later,
       "Failed to capture invoice document #{event.id}, retrying via Stripe"}
    else
      Logger.error("Failed to capture invoice document",
        subscription_id: event.subscription_id,
        stripe_invoice_id: event.id,
        error: error_summary(changeset)
      )

      {:ok, result}
    end
  end

  # Never `inspect/1` a raw changeset here: its `changes` and `params` carry
  # `hosted_invoice_url`/`invoice_pdf_url`, unauthenticated Stripe capability
  # links that must never reach application logs. `changeset.errors` only
  # ever holds field names and validation messages.
  defp error_summary(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)

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
