defmodule Tymeslot.Payments.Webhooks.CheckoutSessionHandler do
  @moduledoc """
  Handler for checkout.session.completed webhook events.
  """
  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger
  alias DBConnection.ConnectionError
  alias Stripe.Error, as: StripeError
  alias Tymeslot.Payments
  alias Tymeslot.Payments.TaxExtractor

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type), do: event_type == "checkout.session.completed"

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(session) do
    # Trust Stripe's data - just ensure we have an ID
    case Map.get(session, "id") do
      nil -> {:error, :missing_field, "Session ID missing"}
      "" -> {:error, :missing_field, "Session ID empty"}
      _id -> :ok
    end
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(_event, session) do
    session_id = Map.get(session, "id")
    mode = Map.get(session, "mode")
    Logger.info("Processing checkout.session.completed", session_id: session_id, mode: mode)

    case mode do
      "subscription" ->
        handle_subscription_completion(session)

      _ ->
        handle_payment_completion(session)
    end
  end

  defp handle_payment_completion(session) do
    session_id = session["id"]
    tax_info = TaxExtractor.extract_tax_info(session)

    case Payments.process_successful_payment(session_id, tax_info) do
      {:ok, :payment_processed} ->
        {:ok, :payment_processed}

      {:error, %StripeError{} = error} ->
        handle_retryable_error(error, session_id)

      {:error, %ConnectionError{} = error} ->
        {:error, :retry_later, "Database connection error: #{Exception.message(error)}"}

      {:error, reason} ->
        Logger.error("Payment processing failed",
          session_id: session_id,
          error: inspect(reason),
          session_data: Map.take(session, ["id", "metadata", "total_details", "customer_details"])
        )

        {:error, :payment_failed, "Payment processing failed: #{inspect(reason)}"}
    end
  end

  defp handle_subscription_completion(session) do
    manager = Application.get_env(:tymeslot, :subscription_manager)

    if manager do
      case manager.handle_checkout_completed(session) do
        {:ok, _transaction} ->
          {:ok, :subscription_processed}

        {:error, reason} ->
          Logger.error("Subscription processing failed",
            session_id: session["id"],
            error: inspect(reason)
          )

          {:error, :subscription_failed, "Subscription processing failed: #{inspect(reason)}"}
      end
    else
      Logger.error("Subscription manager not configured for subscription completion")
      {:error, :subscriptions_not_supported, "Subscription manager not configured"}
    end
  end

  defp handle_retryable_error(error, session_id) do
    if retryable_stripe_error?(error) do
      {:error, :retry_later, "Stripe error for session #{session_id}: #{error.message}"}
    else
      Logger.error("Payment processing failed",
        session_id: session_id,
        error: inspect(error)
      )

      {:error, :payment_failed, "Payment processing failed: #{inspect(error)}"}
    end
  end

  defp retryable_stripe_error?(%StripeError{extra: %{http_status: status}})
       when is_integer(status) do
    status >= 500 or status == 429
  end

  defp retryable_stripe_error?(%StripeError{source: :network}), do: true
  defp retryable_stripe_error?(_), do: false
end
