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
  seconds. A secondary `event["created"]` age check is redundant and harmful —
  Stripe retries carry the original `created` timestamp, so such a check would
  permanently drop any event whose first delivery failed transiently.
  Per-event idempotency is provided by `last_event_id` on `booking_payments`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Webhooks.WebhookRegistry
  alias Tymeslot.Utils.MapKeys

  @type process_result :: :ok | {:error, term()}

  @spec process(binary(), String.t(), String.t()) :: process_result()
  def process(payload, signature, secret) do
    case StripeAdapter.construct_webhook_event(payload, signature, secret) do
      {:ok, event} ->
        dispatch(event)

      {:error, reason} ->
        # Normalise signature/payload errors to a single atom so the controller
        # can distinguish permanent rejections from transient handler failures.
        Logger.warning("Connect webhook signature verification failed", reason: inspect(reason))
        {:error, :signature_failure}
    end
  end

  defp dispatch(event) do
    type = MapKeys.get(event, :type)

    case WebhookRegistry.handler_for(type) do
      nil ->
        Logger.info("Ignoring unhandled Connect webhook event", event_type: type)
        :ok

      handler ->
        Logger.info("Dispatching Connect webhook event",
          event_type: type,
          event_id: MapKeys.get(event, :id)
        )

        handler.handle(event)
    end
  end
end
