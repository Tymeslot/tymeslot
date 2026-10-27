defmodule Tymeslot.Payments.Behaviours.WebhookHandler do
  @moduledoc """
  The one contract for a Stripe webhook event handler, on both the platform
  and the Connect endpoint (`Tymeslot.Payments.Webhooks.Ingress`).

  `handle/1` receives the verified event as the string-keyed map Stripe sent,
  with the object under `event["data"]["object"]`, and answers with one of:

    * `:ok` or `{:ok, term}`: the event is done; the ingress marks it
      processed and acknowledges it.
    * `{:error, :retry_later, reason}`: a failure a later delivery can get
      past (a database or Stripe outage, a downstream hand-off that failed).
      The reservation is released and Stripe redelivers.
    * `{:error, :permanent, reason}`: an event no redelivery can fix, such as
      a malformed object. It is marked processed and acknowledged, so Stripe
      stops sending it.

  Retrying is the default: a handler that raises, or returns any other shape,
  is retried, because acknowledging a failure loses a payment event for good
  while redelivering it costs only another attempt. A handler returns
  `:permanent` only for an event it has positively recognised as unusable.
  """

  @type event :: %{optional(String.t()) => term()}
  @type result :: :ok | {:ok, term()} | {:error, :retry_later | :permanent, term()}

  @callback handle(event()) :: result()
end
