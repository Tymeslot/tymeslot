defmodule Tymeslot.Payments.Webhooks.CheckoutSessionHandler do
  @moduledoc """
  Handler for checkout.session.completed webhook events.
  """
  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

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

      _other ->
        # The platform account only ever creates subscription-mode sessions
        # (Payments.Stripe.create_checkout_session_for_subscription/1); paid
        # bookings run through the separate Connect checkout and its own
        # webhook endpoint. A non-subscription mode here is unexpected, so
        # it is logged loudly rather than silently treated as a success.
        Logger.warning("Ignoring checkout.session.completed for unexpected mode",
          session_id: session_id,
          mode: mode
        )

        {:ok, :ignored}
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
end
