defmodule Tymeslot.Payments.Behaviours.PaymentEventHandler do
  @moduledoc """
  Optional hook that receives every subscription, dispute, refund and
  trial-ending event from the platform Stripe webhook, inside the webhook's
  own processing.

  Configured via `config :tymeslot, :payment_event_handler, MyHandler`. Core
  keeps a `nil` default and behaves identically whether or not one is set.

  The hand-off is durable because it is synchronous: Core calls the handler
  before it answers Stripe, and **`{:error, reason}` makes the webhook fail
  with a retry**, so Stripe redelivers the event rather than Core dropping
  it. A handler should therefore do the least it can here (typically
  enqueue a job) and be safe to call again for the same event.

  The event is the same map Core also publishes on the payment-events PubSub
  topic: `%{event: atom, subscription_id: id, subscription_data: map}` for
  subscription changes, `%{event: atom, data: map, timestamp: DateTime}` for
  everything else. Each carries the Stripe event's `event_id`, and
  subscription and dispute events also its `event_created` Unix time (at the
  top level for a subscription change, in `data` for a dispute), so a
  receiver can deduplicate redeliveries and ignore an event older than one it
  has already applied: Stripe does not deliver them in order.
  """

  @callback handle_payment_event(event :: map()) :: :ok | {:error, term()}
end
