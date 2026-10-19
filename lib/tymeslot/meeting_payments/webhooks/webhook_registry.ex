defmodule Tymeslot.MeetingPayments.Webhooks.WebhookRegistry do
  @moduledoc """
  Maps Stripe Connect event types to per-event handler modules. The
  registry intentionally only knows about the small set of events the
  meeting-payments feature subscribes to; any other event from Stripe
  is unhandled (`nil`), and `Tymeslot.Payments.Webhooks.Ingress` logs it
  and acknowledges it.
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

  @spec handler_for(String.t()) :: module() | :ignore | nil
  def handler_for(event_type), do: Map.get(handlers(), event_type)

  # A function rather than a module attribute, as in the platform registry,
  # so this module is not a compile-time dependant of every handler.
  defp handlers do
    %{
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
  end
end
