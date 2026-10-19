defmodule Tymeslot.Payments.Webhooks.CheckoutSessionExpiredHandler do
  @moduledoc """
  Handler for checkout.session.expired webhook events.
  """
  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Payments
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  @impl WebhookHandler
  def handle(%{"data" => %{"object" => %{"id" => session_id}}})
      when is_binary(session_id) and session_id != "" do
    Logger.info("Processing checkout.session.expired", session_id: session_id)

    case Payments.process_failed_payment(session_id) do
      {:ok, _result} ->
        {:ok, :event_processed}

      {:error, reason} ->
        Logger.error("Failed to process expired session",
          session_id: session_id,
          error: LogFormat.reason(reason)
        )

        {:error, :retry_later, {:processing_failed, reason}}
    end
  end

  def handle(_event), do: {:error, :permanent, :missing_session_id}
end
