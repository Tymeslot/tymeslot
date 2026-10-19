defmodule Tymeslot.Payments.Webhooks.WebhookRegistry do
  @moduledoc """
  Maps each platform Stripe event type to its handler, or to `:ignore` for
  a type the platform endpoint receives but deliberately takes no action on.

  An event type listed here neither way is unexpected, and
  `Tymeslot.Payments.Webhooks.Ingress` raises an admin alert for it.
  """

  alias Tymeslot.Payments.Webhooks.{
    CheckoutSessionExpiredHandler,
    CheckoutSessionHandler,
    DisputeHandler,
    InvoiceHandler,
    RefundHandler,
    SubscriptionHandler,
    TrialWillEndHandler
  }

  # A function rather than a module attribute: an attribute is evaluated at
  # compile time, which would make this module a compile-time dependant of
  # every handler.
  defp handlers do
    %{
      "checkout.session.completed" => CheckoutSessionHandler,
      "checkout.session.expired" => CheckoutSessionExpiredHandler,
      "customer.subscription.created" => SubscriptionHandler,
      "customer.subscription.updated" => SubscriptionHandler,
      "customer.subscription.deleted" => SubscriptionHandler,
      "customer.subscription.trial_will_end" => TrialWillEndHandler,
      "invoice.created" => InvoiceHandler,
      "invoice.finalized" => InvoiceHandler,
      "invoice.paid" => InvoiceHandler,
      "invoice.payment_succeeded" => InvoiceHandler,
      "invoice.payment_failed" => InvoiceHandler,
      "invoice.upcoming" => InvoiceHandler,
      "invoice.voided" => InvoiceHandler,
      "invoice.marked_uncollectible" => InvoiceHandler,
      "charge.refunded" => RefundHandler,
      "charge.refund.updated" => RefundHandler,
      "charge.dispute.created" => DisputeHandler,
      "charge.dispute.updated" => DisputeHandler,
      "charge.dispute.closed" => DisputeHandler
    }
  end

  # Received but acted on elsewhere or not at all. The payment itself is
  # recorded from checkout.session.completed and the invoice events, so the
  # charge, payment-intent, customer and setup events that accompany it carry
  # nothing further. Connect application-fee events fire on the platform
  # account for every paid booking (the platform fee being collected or
  # returned). `customer.deleted` is the echo of a customer we removed
  # ourselves, for instance when an account is deleted.
  @ignored ~w(
    charge.succeeded
    charge.failed
    payment_intent.created
    payment_intent.succeeded
    customer.created
    customer.updated
    payment_method.attached
    setup_intent.created
    setup_intent.succeeded
    application_fee.created
    application_fee.refunded
    customer.deleted
  )

  @doc """
  The handler for `event_type`, `:ignore` for a deliberately ignored type,
  or `nil` for an unexpected one.
  """
  @spec handler_for(String.t()) :: module() | :ignore | nil
  def handler_for(event_type) do
    case Map.fetch(handlers(), event_type) do
      {:ok, handler} -> handler
      :error when event_type in @ignored -> :ignore
      :error -> nil
    end
  end
end
