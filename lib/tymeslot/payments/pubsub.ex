defmodule Tymeslot.Payments.PubSub do
  @moduledoc """
  Handles PubSub broadcasting for payment-related events.

  This module provides a centralized way to broadcast payment events
  to apps, allowing them to handle app-specific logic (like confirmation emails)
  without coupling the payment library to specific app implementations.

  Topic names are private to this module. Subscribers go through
  `subscribe_to_payment_events/0` (re-exported by the `Tymeslot.Payments`
  context) rather than building a topic and resolving the PubSub server
  themselves, so renaming a topic here cannot silently orphan a subscriber.
  """
  require Logger

  alias Phoenix.PubSub
  alias Tymeslot.Infrastructure.AdminAlerts

  # The topic every payment lifecycle event is published on.
  @payment_events_topic "payment_events:tymeslot"

  @doc """
  Subscribes the calling process to the payment-events topic.

  Returns `{:error, reason}` instead of raising when no PubSub server is
  running, so a supervised subscriber can start without one.
  """
  @spec subscribe_to_payment_events() :: :ok | {:error, term()}
  def subscribe_to_payment_events, do: subscribe(@payment_events_topic)

  @doc """
  Broadcasts a message on the payment-events topic.
  """
  @spec broadcast_to_payment_events(term()) :: :ok | {:error, term()}
  def broadcast_to_payment_events(message), do: broadcast(@payment_events_topic, message)

  defp subscribe(topic) do
    case get_pubsub_server() do
      nil ->
        Logger.warning("No PubSub server found, skipping subscribe", topic: topic)
        {:error, :no_pubsub_server}

      pubsub_server ->
        PubSub.subscribe(pubsub_server, topic)
    end
  rescue
    # Phoenix.PubSub.subscribe/2 raises when the server is named but its
    # registry is not running (a race against application start).
    error -> {:error, error}
  end

  @doc """
  General broadcast function to send any event to PubSub.
  """
  @spec broadcast(String.t(), any()) :: :ok | {:error, any()}
  def broadcast(topic, message) do
    pubsub_server = get_pubsub_server()

    if pubsub_server do
      PubSub.broadcast(pubsub_server, topic, message)
    else
      Logger.warning("No PubSub server found, skipping broadcast")
      {:error, :no_pubsub_server}
    end
  end

  @doc """
  Broadcasts a subscription event.
  Used for events like :subscription_created, :subscription_canceled, :subscription_updated.
  """
  @spec broadcast_subscription_event(%{
          required(:event) => atom(),
          required(:user_id) => integer(),
          optional(atom()) => term()
        }) :: :ok
  def broadcast_subscription_event(event_data) do
    case broadcast_to_payment_events(event_data) do
      :ok ->
        :ok

      {:error, reason} ->
        user_id = Map.get(event_data, :user_id)
        event_type = Map.get(event_data, :event)

        Logger.error("PubSub broadcast failed for subscription_event",
          event: event_type,
          user_id: user_id,
          reason: inspect(reason)
        )

        AdminAlerts.report(:pubsub_broadcast_failed,
          summary: "PubSub broadcast failed for subscription_event",
          reason: reason,
          context: %{
            event: :subscription_event,
            topic: @payment_events_topic,
            event_type: event_type,
            user_id: user_id
          }
        )

        :ok
    end
  end

  @doc """
  Broadcasts a payment event that might need SaaS handling.
  """
  @spec broadcast_payment_event(atom(), map()) :: :ok
  def broadcast_payment_event(event_type, event_data) do
    message = %{
      event: event_type,
      data: event_data,
      timestamp: DateTime.utc_now()
    }

    case broadcast_to_payment_events(message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("PubSub broadcast failed for payment_event",
          event: event_type,
          reason: inspect(reason)
        )

        AdminAlerts.report(:pubsub_broadcast_failed,
          summary: "PubSub broadcast failed for payment_event",
          reason: reason,
          context: %{
            event: :payment_event,
            topic: @payment_events_topic,
            event_type: event_type
          }
        )

        :ok
    end
  end

  @doc """
  Gets the PubSub server name.

  ## Parameters
  ## Returns
  - The PubSub module atom if found and running
  - `nil` if the PubSub server doesn't exist or isn't running
  """
  @spec get_pubsub_server() :: module() | nil
  def get_pubsub_server do
    force_app_pubsub? = Application.get_env(:tymeslot, :force_app_pubsub_in_test, false)

    # Use test PubSub server in test unless explicitly forced to use app PubSub
    if !force_app_pubsub? and
         (Application.get_env(:tymeslot, :test_mode, false) or test_env?()) do
      Tymeslot.TestPubSub
    else
      pubsub_module_name = "Tymeslot.PubSub"

      try do
        # Convert string to existing atom (will raise if module doesn't exist)
        pubsub_module = String.to_existing_atom("Elixir.#{pubsub_module_name}")

        # Check if the process is actually running
        if Process.whereis(pubsub_module) do
          pubsub_module
        else
          Logger.warning("PubSub server not running", module: pubsub_module_name)
          nil
        end
      rescue
        ArgumentError ->
          Logger.warning("PubSub module does not exist", module: pubsub_module_name)
          nil
      end
    end
  end

  defp test_env? do
    Application.get_env(:tymeslot, :env, :prod) == :test or
      System.get_env("MIX_ENV") == "test"
  end
end
