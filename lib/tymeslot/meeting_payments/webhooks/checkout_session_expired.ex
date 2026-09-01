defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired do
  @moduledoc """
  Handler for the Stripe `checkout.session.expired` Connect event.

  Stripe expires a Checkout Session after 30 minutes of inactivity (or earlier
  when explicitly cancelled). The booking payment is marked `failed` and the
  meeting transitions from `awaiting_payment` to `expired`, releasing the slot;
  no email or calendar push is triggered, since there is nothing to confirm.

  The flow is shared with `CheckoutSessionAsyncPaymentFailed` via
  `Tymeslot.MeetingPayments.Webhooks.FailAndExpire`. Idempotent on
  `last_event_id`; safe to invoke again on Stripe retry.
  """

  alias Tymeslot.MeetingPayments.Webhooks.FailAndExpire

  @event_type "checkout.session.expired"

  @spec handle(map()) :: {:ok, atom()} | {{:error, term()}, :error}
  def handle(event) do
    FailAndExpire.handle(event, @event_type, :webhook_expired)
  end
end
