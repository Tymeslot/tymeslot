defmodule TymeslotWeb.StripeConnectWebhookController do
  @moduledoc """
  Receives Stripe Connect webhooks for booking-payment events.

  Distinct from `StripeWebhookController` (which handles platform-level
  subscription events) — this endpoint uses
  `STRIPE_CONNECT_WEBHOOK_SECRET` and dispatches via
  `Tymeslot.MeetingPayments.Webhooks.WebhookProcessor`.

  HTTP status semantics:
  - 200 — event verified and dispatched (or silently ignored for unknown types)
  - 400 — payload-level rejection (invalid signature, malformed event); Stripe
          will NOT retry these
  - 503 — transient handler error (DB failure, downstream API error); Stripe
          WILL retry these

  Side effects happen inside per-event handlers so the controller stays thin.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Tymeslot.MeetingPayments.Webhooks.WebhookProcessor

  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, _params) do
    payload = conn.assigns[:raw_body] || ""

    signature = conn |> get_req_header("stripe-signature") |> List.first() |> nil_to_empty()

    case Application.get_env(:tymeslot, :stripe_connect_webhook_secret) do
      secret when is_binary(secret) and secret != "" ->
        process(conn, payload, signature, secret)

      _missing ->
        Logger.error("Connect webhook secret is not configured")
        send_resp(conn, 400, "")
    end
  end

  defp nil_to_empty(nil), do: ""
  defp nil_to_empty(value), do: value

  # Errors produced by signature verification — payload-level rejections that
  # Stripe should not retry (the payload itself is invalid or unrecognised).
  @permanent_errors [:signature_failure, :invalid_event]

  defp process(conn, payload, signature, secret) do
    case WebhookProcessor.process(payload, signature, secret) do
      :ok ->
        send_resp(conn, 200, "")

      {:error, reason} when reason in @permanent_errors ->
        Logger.warning("Connect webhook rejected (permanent)", reason: inspect(reason))
        send_resp(conn, 400, "")

      {:error, reason} ->
        # Treat all other errors (DB failures, Stripe API errors, handler
        # crashes) as transient so Stripe will retry delivery.
        Logger.warning("Connect webhook handler error (transient)", reason: inspect(reason))
        send_resp(conn, 503, "")
    end
  end
end
