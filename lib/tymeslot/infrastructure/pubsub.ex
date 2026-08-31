defmodule Tymeslot.Infrastructure.PubSub do
  @moduledoc """
  Handles PubSub broadcasting for auth-related events.

  This module provides a centralized way to broadcast authentication events
  within the Tymeslot application.

  The topic name is private to this module. Subscribers go through
  `Tymeslot.Auth.subscribe_to_user_registrations/0`, which re-exports
  `subscribe_to_user_registrations/0` below, rather than resolving the PubSub
  server and spelling a topic themselves, so renaming the topic here cannot
  silently orphan a subscriber.
  """

  @behaviour Tymeslot.Auth.Behaviours.UserBroadcaster

  require Logger

  # The topic every user-registration event is published on.
  @user_registered_topic "auth:user_registered"

  @doc """
  Broadcasts a user registration event via PubSub.

  ## Parameters
  - `user`: The newly registered user struct
  - `metadata`: Optional map of additional data (default: %{})

  ## Example
      Tymeslot.Infrastructure.PubSub.broadcast_user_registered(user, %{source: "signup"})
  """
  @impl Tymeslot.Auth.Behaviours.UserBroadcaster
  @spec broadcast_user_registered(struct(), map()) :: :ok
  def broadcast_user_registered(user, metadata \\ %{}) do
    message = {:user_registered, %{user: user, metadata: metadata}}

    case Phoenix.PubSub.broadcast(Tymeslot.PubSub, @user_registered_topic, message) do
      :ok ->
        Logger.info("Broadcasted user_registered event", user_id: user.id)

      {:error, reason} ->
        Logger.warning("Failed to broadcast user_registered event", reason: inspect(reason))
    end

    :ok
  end

  @doc """
  Subscribes the calling process to user-registration events.

  Every account that completes registration arrives in the caller's mailbox as
  `{:user_registered, %{user: user, metadata: metadata}}`. Returns
  `{:error, reason}` rather than raising when no PubSub server is running, so
  the caller decides whether a missing subscription is fatal.
  """
  @spec subscribe_to_user_registrations() :: :ok | {:error, term()}
  def subscribe_to_user_registrations do
    case Process.whereis(Tymeslot.PubSub) do
      nil ->
        Logger.warning("No PubSub server found, skipping subscribe",
          topic: @user_registered_topic
        )

        {:error, :no_pubsub_server}

      _pid ->
        Phoenix.PubSub.subscribe(Tymeslot.PubSub, @user_registered_topic)
    end
  rescue
    # Phoenix.PubSub.subscribe/2 raises when the server is named but its
    # registry is not running (a race against application start).
    error -> {:error, error}
  end
end
