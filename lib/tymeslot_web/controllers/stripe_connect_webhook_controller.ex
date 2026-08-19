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

  Stripe explicitly documents that the same event can be delivered more than
  once, so a replay must not repeat those side effects. Deduplication mirrors
  the platform webhook path (`StripeWebhookPlug`): reserve the event ID in
  `IdempotencyCache` before dispatch, then mark it processed or release the
  reservation depending on the outcome. The event ID is read straight off the
  raw JSON payload (not the signature-verified event, which only the
  `MeetingPayments` facade — not this controller — is allowed to construct)
  purely as a cache key; it carries no trust and every dispatch still goes
  through full signature verification.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Tymeslot.MeetingPayments
  alias Tymeslot.Payments.Webhooks.IdempotencyCache

  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, _params) do
    payload = conn.assigns[:raw_body] || ""

    signature = conn |> get_req_header("stripe-signature") |> List.first() |> nil_to_empty()

    case Application.get_env(:tymeslot, :stripe_connect_webhook_secret) do
      secret when is_binary(secret) and secret != "" ->
        process(conn, payload, signature, secret)

      _missing ->
        Logger.error("Connect webhook secret is not configured")
        send_resp(conn, 503, "")
    end
  end

  defp nil_to_empty(nil), do: ""
  defp nil_to_empty(value), do: value

  # Errors produced by signature verification — payload-level rejections that
  # Stripe should not retry (the payload itself is invalid or unrecognised).
  @permanent_errors [:signature_failure, :invalid_event]

  defp process(conn, payload, signature, secret) do
    case raw_event_id(payload) do
      {:ok, event_id} -> process_with_idempotency(conn, payload, signature, secret, event_id)
      :error -> dispatch(conn, payload, signature, secret)
    end
  end

  defp process_with_idempotency(conn, payload, signature, secret, event_id) do
    case IdempotencyCache.reserve(event_id) do
      {:ok, :reserved} ->
        conn
        |> dispatch(payload, signature, secret)
        |> settle_reservation(event_id)

      {:ok, :in_progress} ->
        Logger.info("Connect webhook already in progress, asking Stripe to retry",
          event_id: event_id
        )

        send_resp(conn, 503, "")

      {:ok, :already_processed} ->
        Logger.info("Skipping already-processed Connect webhook", event_id: event_id)
        send_resp(conn, 200, "")
    end
  end

  defp dispatch(conn, payload, signature, secret) do
    case MeetingPayments.process_webhook(payload, signature, secret) do
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

  # 200 and 400 are terminal for this event (dispatched, or permanently
  # rejected) so the reservation is confirmed; 503 means Stripe will retry,
  # so the reservation is released to allow that retry through.
  defp settle_reservation(%{status: 503} = conn, event_id) do
    IdempotencyCache.release(event_id)
    conn
  end

  defp settle_reservation(conn, event_id) do
    IdempotencyCache.mark_processed(event_id)
    conn
  end

  defp raw_event_id(payload) do
    with {:ok, decoded} <- Jason.decode(payload),
         id when is_binary(id) and id != "" <- Map.get(decoded, "id") do
      {:ok, id}
    else
      _unusable -> :error
    end
  end
end
