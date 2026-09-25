defmodule TymeslotWeb.StripeWebhookController do
  @moduledoc """
  Receives Stripe webhooks on two endpoints with distinct signing secrets:

    * `webhook/2` (`/webhooks/stripe`): platform events such as
      subscriptions and invoices, verified with `STRIPE_WEBHOOK_SECRET` and
      processed by `Tymeslot.Payments.Webhooks.Delivery`.
    * `connect/2` (`/webhooks/stripe/connect`): Connect events for booking
      payments, verified with `STRIPE_CONNECT_WEBHOOK_SECRET` and processed by
      `Tymeslot.MeetingPayments.process_webhook/2`.

  Both run behind `TymeslotWeb.Plugs.StripeWebhookPlug` (rate limiting) and
  share one deduplication policy, `Tymeslot.Payments.Webhooks.Idempotency`,
  so this controller only maps the domain outcome to a status. Every response
  has an empty body; the reason is in the logs, never sent to the caller.

    * 200: processed, a duplicate, or failed permanently (acknowledged so
      Stripe stops redelivering an event that cannot succeed)
    * 400: signature or payload rejected
    * 503: transient failure or missing signing secret; Stripe retries
  """

  use TymeslotWeb, :controller

  alias Tymeslot.MeetingPayments
  alias Tymeslot.Payments.Webhooks.Delivery

  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, _params),
    do: respond(conn, Delivery.process(raw_body(conn), signature(conn)))

  @spec connect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def connect(conn, _params),
    do: respond(conn, MeetingPayments.process_webhook(raw_body(conn), signature(conn)))

  # `WebhookBodyCachePlug` caches the raw body for the configured webhook
  # paths; without it there is nothing a signature can verify against.
  defp raw_body(conn), do: conn.assigns[:raw_body] || ""

  defp signature(conn), do: conn |> get_req_header("stripe-signature") |> List.first()

  defp respond(conn, {:ok, _processed_or_duplicate}), do: send_resp(conn, 200, "")
  defp respond(conn, {:error, :permanent}), do: send_resp(conn, 200, "")

  defp respond(conn, {:error, reason}) when reason in [:invalid_signature, :invalid_payload],
    do: send_resp(conn, 400, "")

  defp respond(conn, {:error, reason}) when reason in [:retry_later, :not_configured],
    do: send_resp(conn, 503, "")
end
