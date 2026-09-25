defmodule Tymeslot.MeetingPayments.Webhooks.WebhookProcessor do
  @moduledoc """
  Verifies a Stripe Connect webhook payload and dispatches to a per-event
  handler.

  Distinct from `Tymeslot.Payments.Webhooks.WebhookProcessor` — that one
  handles platform-level subscription events; this one handles
  Connect-account events tied to booking payments. Different signing
  secrets, different registries, different handlers.

  Replay protection is handled by `construct_webhook_event/3` itself: Stripe's
  signature verification rejects events whose `t=` timestamp is older than 300
  seconds. A secondary `event["created"]` age check is redundant and harmful:
  Stripe retries carry the original `created` timestamp, so such a check would
  permanently drop any event whose first delivery failed transiently.

  Redelivery of the same event is deduplicated by the platform path's policy,
  `Tymeslot.Payments.Webhooks.Idempotency`, once the signature has been
  verified; `last_event_id` on `booking_payments` remains a second line of
  defence inside the handlers.
  """

  require Logger

  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Webhooks.WebhookRegistry
  alias Tymeslot.Payments.Webhooks.Idempotency

  @type process_result ::
          Idempotency.result()
          | {:error, :not_configured | :invalid_signature | :invalid_payload}

  @doc """
  Verifies `payload` against `signature` with the Connect signing secret and
  dispatches the event to its handler, at most once per event id.

  Returns `{:error, :not_configured}` when `STRIPE_CONNECT_WEBHOOK_SECRET` is
  unset, `{:error, :invalid_signature}` when verification fails, and
  `{:error, :invalid_payload}` for a verified event without an id. Otherwise
  returns the `t:Idempotency.result/0` of the dispatch: a handler's
  `{:error, :invalid_event}` (a malformed event, which no retry can fix) is
  permanent, and any other handler error (a database or Stripe API failure)
  is retried.
  """
  @spec process(binary(), String.t() | nil) :: process_result()
  def process(payload, signature) do
    with {:ok, secret} <- fetch_secret(),
         {:ok, event} <- verify(payload, signature, secret),
         {:ok, event_id} <- fetch_event_id(event) do
      Idempotency.with_idempotency(event_id, event["type"], fn -> dispatch(event) end)
    end
  end

  defp fetch_secret do
    case Application.get_env(:tymeslot, :stripe_connect_webhook_secret) do
      secret when is_binary(secret) and secret != "" ->
        {:ok, secret}

      _missing ->
        Logger.error("Connect webhook secret is not configured")
        {:error, :not_configured}
    end
  end

  defp verify(payload, signature, secret) do
    case StripeAdapter.construct_webhook_event(payload, signature || "", secret) do
      {:ok, event} ->
        {:ok, event}

      {:error, reason} ->
        Logger.warning("Connect webhook signature verification failed", reason: inspect(reason))
        {:error, :invalid_signature}
    end
  end

  # `construct_webhook_event/3` returns a string-keyed map (see
  # `StripeAdapter.normalise/1`), so the keys are read directly from here on.
  defp fetch_event_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}

  defp fetch_event_id(_event) do
    Logger.warning("Connect webhook rejected: verified event carries no id")
    {:error, :invalid_payload}
  end

  defp dispatch(%{"type" => type} = event) do
    case WebhookRegistry.handler_for(type) do
      nil ->
        Logger.info("Ignoring unhandled Connect webhook event", event_type: type)
        {:ok, :ignored}

      handler ->
        Logger.info("Dispatching Connect webhook event", event_type: type, event_id: event["id"])
        event |> handler.handle() |> retry_unless_malformed()
    end
  end

  defp dispatch(_event), do: {:error, :invalid_event}

  defp retry_unless_malformed({:error, :invalid_event} = permanent), do: permanent
  defp retry_unless_malformed({:error, reason}), do: {:error, :retry_later, reason}
  defp retry_unless_malformed(result), do: result
end
