defmodule TymeslotWeb.StripeWebhookController do
  use TymeslotWeb, :controller
  require Logger

  alias Tymeslot.Payments.Errors.WebhookError
  alias Tymeslot.Payments.Webhooks.{IdempotencyCache, WebhookProcessor}

  @typedoc "Webhook processing result status"
  @type webhook_status :: atom()

  # Webhook plug is now in the router pipeline, not here

  @doc """
  Handles incoming Stripe webhook events.
  """
  @spec webhook(term(), map()) :: term()
  def webhook(conn, params) do
    # Log the incoming webhook request
    Logger.info("Stripe webhook received",
      request_path: conn.request_path,
      method: conn.method,
      params_keys: Map.keys(params),
      headers: stripe_headers(conn)
    )

    case conn.assigns[:stripe_event] do
      nil ->
        # No event was assigned by the plug (likely an error occurred)
        Logger.error("No Stripe event assigned by plug")
        send_resp(conn, 400, "Invalid webhook payload")

      event ->
        start_time = System.monotonic_time(:millisecond)
        result = WebhookProcessor.process_event(event)
        processing_time = System.monotonic_time(:millisecond) - start_time

        # Handle the result, ensuring backward compatibility
        normalized_result = normalize_result(result)
        event_type = Map.get(event, :type) || Map.get(event, "type")
        event_id = Map.get(event, :id) || Map.get(event, "id")

        case normalized_result do
          {:ok, status} ->
            log_processing_result({:ok, status}, event_type, processing_time)

            # Mark as processed in cache and database to prevent duplicate processing
            if event_id do
              IdempotencyCache.mark_processed(event_id, event_type, event)
            end

            # Always return 200 to acknowledge receipt
            send_resp(conn, 200, "")

          {:error, :retry_later, message} ->
            log_processing_result({:error, :retry_later}, event_type, processing_time)

            # Return 503 so Stripe retries this specific event
            # This is used for race conditions (e.g. invoice arrives before subscription record is created)
            # We DON'T mark it as processed here so it can be retried
            if event_id do
              IdempotencyCache.release(event_id)
            end

            send_resp(conn, 503, message || "Service Unavailable")

          {:error, error, _message} ->
            log_processing_result({:error, error}, event_type, processing_time)

            # Mark as processed even on error if it's not a retryable error
            # This prevents infinite retries for errors we can't fix
            if event_id do
              IdempotencyCache.mark_processed(event_id, event_type, event)
            end

            # Always return 200 to Stripe for other errors
            send_resp(conn, 200, "")
        end
    end
  end

  # Private functions

  # Normalize result to a single error shape and ok atom for controller handling
  @type webhook_error :: atom() | Exception.t()
  @spec normalize_result(
          {:ok, webhook_status()}
          | {:error, webhook_error, String.t() | nil}
        ) ::
          {:ok, webhook_status()} | {:error, webhook_error, String.t() | nil}
  defp normalize_result({:ok, status}) when is_atom(status), do: {:ok, status}

  defp normalize_result({:error, reason, message}) when is_binary(message) or is_nil(message),
    do: {:error, reason, message}

  @spec log_processing_result(
          {:ok, webhook_status()} | {:error, term()},
          String.t(),
          non_neg_integer()
        ) :: :ok
  defp log_processing_result(result, event_type, processing_time) do
    case result do
      {:ok, status} ->
        Logger.info("Webhook processed successfully",
          event_type: event_type,
          status: status,
          processing_time_ms: processing_time
        )

      {:error, %WebhookError.ProcessingError{} = error} ->
        Logger.error("Webhook processing error",
          event_type: event_type,
          error_reason: error.reason,
          error_message: error.message,
          processing_time_ms: processing_time
        )

      {:error, %WebhookError.ValidationError{} = error} ->
        Logger.error("Webhook validation error",
          event_type: event_type,
          error_reason: error.reason,
          error_message: error.message,
          processing_time_ms: processing_time
        )

      {:error, error} ->
        Logger.error("Webhook error",
          event_type: event_type,
          error: inspect(error),
          processing_time_ms: processing_time
        )
    end

    :ok
  end

  defp stripe_headers(conn) do
    conn.req_headers
    |> Enum.filter(fn {k, _value} -> String.contains?(k, "stripe") end)
    |> Enum.map(fn
      {"stripe-signature", _value} -> {"stripe-signature", "[redacted]"}
      header -> header
    end)
  end
end
