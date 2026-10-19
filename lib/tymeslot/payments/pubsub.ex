defmodule Tymeslot.Payments.PubSub do
  @moduledoc """
  Hands payment events from the Stripe webhooks to the configured
  `:payment_event_handler`.

  The handler is the one durable consumer: it runs inside the webhook's
  processing, and its `{:error, reason}` fails the delivery so Stripe sends
  the event again. With no handler configured (a standalone installation
  that does not sell subscriptions), the hand-off does nothing.
  """
  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat

  @doc """
  Hands a webhook's payment event (dispute, refund, trial ending) to the
  configured `:payment_event_handler`.

  Returns the handler's `{:error, reason}`, so the calling webhook handler
  can fail the delivery and Stripe redelivers the event.
  """
  @spec hand_off_payment_event(atom(), map()) :: :ok | {:error, term()}
  def hand_off_payment_event(event_type, event_data) do
    hand_off(%{event: event_type, data: event_data, timestamp: DateTime.utc_now()})
  end

  @doc """
  Hands a webhook's subscription event to the configured
  `:payment_event_handler`. See `hand_off_payment_event/2` for the outcomes.
  """
  @spec hand_off_subscription_event(%{
          required(:event) => atom(),
          required(:subscription_id) => String.t(),
          required(:subscription_data) => map(),
          optional(atom()) => term()
        }) :: :ok | {:error, term()}
  def hand_off_subscription_event(message), do: hand_off(message)

  defp hand_off(%{event: event_type} = message) do
    case Application.get_env(:tymeslot, :payment_event_handler) do
      nil ->
        :ok

      handler ->
        case handler.handle_payment_event(message) do
          :ok ->
            :ok

          {:error, reason} = error ->
            Logger.error("Payment event handler failed, the webhook will be retried",
              event: event_type,
              reason: LogFormat.reason(reason)
            )

            error
        end
    end
  end
end
