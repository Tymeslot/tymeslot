defmodule Tymeslot.MeetingPayments.Webhooks.WebhookRegistry do
  @moduledoc """
  Maps Stripe Connect event types to per-event handler modules. The
  registry intentionally only knows about the small set of events the
  meeting-payments feature subscribes to — any other event from Stripe
  is treated as unhandled (returns `nil`) and the processor logs it and
  moves on.
  """

  alias Tymeslot.MeetingPayments.Webhooks.{
    AccountUpdated,
    ChargeDisputeClosed,
    ChargeDisputeCreated,
    ChargeRefunded,
    CheckoutSessionAsyncPaymentFailed,
    CheckoutSessionCompleted,
    CheckoutSessionExpired
  }

  @handlers %{
    "checkout.session.completed" => CheckoutSessionCompleted,
    # An asynchronous payment method (e.g. SEPA Direct Debit) that settles
    # after Checkout completes fires this event with the session in its
    # final "paid" state. Reusing the same handler is safe: its
    # `payment_status == "paid"` gate is exactly what makes this event
    # confirmable, and it is idempotent on `last_event_id` like any replay.
    "checkout.session.async_payment_succeeded" => CheckoutSessionCompleted,
    "checkout.session.async_payment_failed" => CheckoutSessionAsyncPaymentFailed,
    "checkout.session.expired" => CheckoutSessionExpired,
    "charge.refunded" => ChargeRefunded,
    "charge.dispute.created" => ChargeDisputeCreated,
    "charge.dispute.closed" => ChargeDisputeClosed,
    "account.updated" => AccountUpdated
  }

  @spec handler_for(String.t()) :: module() | nil
  def handler_for(event_type), do: Map.get(@handlers, event_type)

  @spec handled_event_types() :: [String.t()]
  def handled_event_types, do: Map.keys(@handlers)
end
