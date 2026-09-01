defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionAsyncPaymentFailed do
  @moduledoc """
  Handler for the Stripe `checkout.session.async_payment_failed` Connect event.

  Fires when an asynchronous payment method attached to a Checkout Session
  (e.g. SEPA Direct Debit) ultimately fails to settle, after
  `checkout.session.completed` already arrived with `payment_status: "unpaid"`.
  The booking payment is marked `failed` and the meeting transitions from
  `awaiting_payment` to `expired`, releasing the slot; no email or calendar push
  is triggered, since there is nothing to confirm.

  The flow is shared with `CheckoutSessionExpired` via
  `Tymeslot.MeetingPayments.Webhooks.FailAndExpire`. Idempotent on
  `last_event_id`; safe to invoke again on Stripe retry.
  """

  alias Tymeslot.MeetingPayments.Webhooks.FailAndExpire

  @event_type "checkout.session.async_payment_failed"

  @spec handle(map()) :: {:ok, atom()} | {{:error, term()}, :error}
  def handle(event) do
    FailAndExpire.handle(event, @event_type, :webhook_async_payment_failed)
  end
end
