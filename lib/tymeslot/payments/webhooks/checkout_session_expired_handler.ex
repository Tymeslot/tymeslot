defmodule Tymeslot.Payments.Webhooks.CheckoutSessionExpiredHandler do
  @moduledoc """
  Handler for checkout.session.expired webhook events.
  """
  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger
  alias Tymeslot.Payments

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type), do: event_type == "checkout.session.expired"

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(session) do
    case Map.get(session, "id") do
      nil -> {:error, :missing_field, "Session ID missing"}
      "" -> {:error, :missing_field, "Session ID empty"}
      _id -> :ok
    end
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(_event, session) do
    session_id = Map.get(session, "id")
    Logger.info("Processing checkout.session.expired", session_id: session_id)

    case Payments.process_failed_payment(session_id) do
      {:ok, _result} ->
        {:ok, :event_processed}

      {:error, reason} ->
        Logger.error("Failed to process expired session",
          session_id: session_id,
          error: inspect(reason)
        )

        {:error, :processing_failed, "Failed to process expired session: #{inspect(reason)}"}
    end
  end
end
