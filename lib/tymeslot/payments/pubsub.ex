defmodule Tymeslot.Payments.PubSub do
  @moduledoc """
  Handles PubSub broadcasting for payment-related events.

  This module provides a centralized way to broadcast payment events
  to apps, allowing them to handle app-specific logic (like confirmation emails)
  without coupling the payment library to specific app implementations.
  """
  require Logger

  alias Phoenix.PubSub
  alias Tymeslot.Infrastructure.AdminAlerts

  @doc """
  Broadcasts a payment success event via PubSub.

  Apps can subscribe to "payment:payment_successful" topic to handle app-specific
  post-payment logic.

  ## Parameters
  - `transaction`: The completed transaction struct

  ## Example
      Tymeslot.Payments.PubSub.broadcast_payment_successful(transaction)
  """
  @spec broadcast_payment_successful(struct()) :: :ok
  def broadcast_payment_successful(transaction) do
    pubsub_server = get_pubsub_server()

    if pubsub_server do
      message =
        {:payment_successful,
         %{
           user_id: transaction.user_id,
           transaction: transaction
         }}

      case PubSub.broadcast(pubsub_server, "payment:payment_successful", message) do
        :ok ->
          Logger.info("Broadcasted payment_successful event", user_id: transaction.user_id)
          :ok

        {:error, reason} ->
          Logger.error("PubSub broadcast failed for payment_successful",
            user_id: transaction.user_id,
            reason: inspect(reason)
          )

          # Alert monitoring system - repeated failures indicate infrastructure issues
          AdminAlerts.send_alert(
            :pubsub_broadcast_failed,
            %{
              event: :payment_successful,
              user_id: transaction.user_id,
              reason: reason
            },
            level: :error
          )

          :ok
      end
    else
      Logger.warning("No PubSub server configured, skipping payment_successful broadcast")
      :ok
    end
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
    topic = "payment_events:tymeslot"

    case broadcast(topic, event_data) do
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

        AdminAlerts.send_alert(
          :pubsub_broadcast_failed,
          %{
            event: :subscription_event,
            event_type: event_type,
            user_id: user_id,
            reason: reason
          },
          level: :error
        )

        :ok
    end
  end

  @doc """
  Broadcasts a payment event that might need SaaS handling.
  """
  @spec broadcast_payment_event(atom(), map()) :: :ok
  def broadcast_payment_event(event_type, event_data) do
    topic = "payment_events:tymeslot"

    message = %{
      event: event_type,
      data: event_data,
      timestamp: DateTime.utc_now()
    }

    case broadcast(topic, message) do
      :ok ->
        :ok

      {:error, reason} ->
        user_id = Map.get(message, :user_id)

        Logger.error("PubSub broadcast failed for payment_event",
          event: event_type,
          user_id: user_id,
          reason: inspect(reason)
        )

        AdminAlerts.send_alert(
          :pubsub_broadcast_failed,
          %{
            event: :payment_event,
            event_type: event_type,
            user_id: user_id,
            reason: reason
          },
          level: :error
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

  @doc """
  Broadcasts a subscription success event via PubSub.

  Apps can subscribe to "payment:subscription_successful" topic to handle app-specific
  post-subscription logic.

  ## Parameters
  - `transaction`: The completed subscription transaction struct

  ## Example
      Tymeslot.Payments.PubSub.broadcast_subscription_successful(transaction)
  """
  @spec broadcast_subscription_successful(struct()) :: :ok
  def broadcast_subscription_successful(transaction) do
    pubsub_server = get_pubsub_server()

    if pubsub_server do
      message =
        {:subscription_successful,
         %{
           user_id: transaction.user_id,
           subscription_id: transaction.subscription_id,
           transaction: transaction
         }}

      case PubSub.broadcast(pubsub_server, "payment:subscription_successful", message) do
        :ok ->
          Logger.info("Broadcasted subscription_successful event", user_id: transaction.user_id)

          :ok

        {:error, reason} ->
          Logger.error("PubSub broadcast failed for subscription_successful",
            user_id: transaction.user_id,
            reason: inspect(reason)
          )

          AdminAlerts.send_alert(
            :pubsub_broadcast_failed,
            %{
              event: :subscription_successful,
              user_id: transaction.user_id,
              reason: reason
            },
            level: :error
          )

          :ok
      end
    else
      Logger.warning("No PubSub server configured, skipping subscription_successful broadcast")
      :ok
    end
  end

  @doc """
  Broadcasts a subscription failure event via PubSub.

  Apps can subscribe to "payment:subscription_failed" topic to handle app-specific
  post-subscription failure logic.

  ## Parameters
  - `transaction`: The failed subscription transaction struct

  ## Example
      Tymeslot.Payments.PubSub.broadcast_subscription_failed(transaction)
  """
  @spec broadcast_subscription_failed(struct()) :: :ok
  def broadcast_subscription_failed(transaction) do
    pubsub_server = get_pubsub_server()

    if pubsub_server do
      message =
        {:subscription_failed,
         %{
           user_id: transaction.user_id,
           subscription_id: transaction.subscription_id,
           transaction: transaction
         }}

      case PubSub.broadcast(pubsub_server, "payment:subscription_failed", message) do
        :ok ->
          Logger.info("Broadcasted subscription_failed event", user_id: transaction.user_id)
          :ok

        {:error, reason} ->
          Logger.error("PubSub broadcast failed for subscription_failed",
            user_id: transaction.user_id,
            reason: inspect(reason)
          )

          AdminAlerts.send_alert(
            :pubsub_broadcast_failed,
            %{
              event: :subscription_failed,
              user_id: transaction.user_id,
              reason: reason
            },
            level: :error
          )

          :ok
      end
    else
      Logger.warning("No PubSub server configured, skipping subscription_failed broadcast")
      :ok
    end
  end
end
