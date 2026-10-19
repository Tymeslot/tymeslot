defmodule Tymeslot.Payments.Webhooks.CheckoutSessionHandler do
  @moduledoc """
  Handler for checkout.session.completed webhook events.
  """
  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  @impl WebhookHandler
  def handle(%{"data" => %{"object" => %{"id" => session_id} = session}})
      when is_binary(session_id) and session_id != "" do
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

  def handle(_event), do: {:error, :permanent, :missing_session_id}

  defp handle_subscription_completion(session) do
    manager = Application.get_env(:tymeslot, :subscription_manager)

    if manager do
      case manager.handle_checkout_completed(session) do
        {:ok, _transaction} ->
          {:ok, :subscription_processed}

        {:error, reason} ->
          Logger.error("Subscription processing failed",
            session_id: session["id"],
            error: LogFormat.reason(reason)
          )

          {:error, :retry_later, {:subscription_failed, reason}}
      end
    else
      Logger.error("Subscription manager not configured for subscription completion")
      {:error, :permanent, :subscriptions_not_supported}
    end
  end
end
