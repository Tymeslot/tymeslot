defmodule Tymeslot.Payments.Webhooks.Delivery do
  @moduledoc """
  Entry point for one delivery of a platform-level Stripe webhook (the
  subscription, invoice and dispute events signed with
  `STRIPE_WEBHOOK_SECRET`).

  Verifies the payload, then hands the event to
  `Tymeslot.Payments.Webhooks.WebhookProcessor` under the shared
  deduplication policy in `Tymeslot.Payments.Webhooks.Idempotency`.
  Connect events for booking payments take the parallel path in
  `Tymeslot.MeetingPayments.process_webhook/2`, with the same outcomes.

  Rejection details are logged here and never returned, so the caller has
  nothing to echo back to an unauthenticated sender.
  """

  require Logger

  alias Tymeslot.Payments.Errors.WebhookError.SignatureError
  alias Tymeslot.Payments.Webhooks.Idempotency
  alias Tymeslot.Payments.Webhooks.Security.{DevelopmentMode, SignatureVerifier}
  alias Tymeslot.Payments.Webhooks.WebhookProcessor

  @type result ::
          Idempotency.result()
          | {:error, :not_configured | :invalid_signature | :invalid_payload}

  @doc """
  Verifies and processes a raw webhook body.

  `signature` is the `Stripe-Signature` header, or `nil` when absent.
  Returns an `t:Idempotency.result/0` for a verified event, otherwise
  `{:error, :not_configured}` (no webhook secret), `{:error, :invalid_signature}`
  or `{:error, :invalid_payload}` (a verified event without an id).
  """
  @spec process(binary(), String.t() | nil) :: result()
  def process(raw_body, signature) when is_binary(raw_body) do
    with {:ok, event} <- verify(raw_body, signature),
         {:ok, event_id, event_type} <- identify(event) do
      Idempotency.with_idempotency(
        event_id,
        event_type,
        fn -> WebhookProcessor.process_event(event) end,
        payload: event
      )
    end
  end

  defp verify(raw_body, signature) do
    case DevelopmentMode.verify_if_allowed(raw_body) do
      {:error, :not_allowed} ->
        raw_body |> SignatureVerifier.verify(signature || "") |> verification_result()

      result ->
        verification_result(result)
    end
  end

  defp verification_result({:ok, _event} = ok), do: ok

  defp verification_result({:error, %SignatureError{reason: :missing_webhook_secret} = error}) do
    Logger.error("Stripe webhook secret is not configured", error: error.message)
    {:error, :not_configured}
  end

  defp verification_result({:error, %SignatureError{} = error}) do
    Logger.warning("Stripe webhook rejected",
      reason: error.reason,
      error: error.message
    )

    {:error, :invalid_signature}
  end

  defp identify(%{"id" => id} = event) when is_binary(id) and id != "",
    do: {:ok, id, Map.get(event, "type")}

  defp identify(_event) do
    Logger.warning("Stripe webhook rejected: verified event carries no id")
    {:error, :invalid_payload}
  end
end
