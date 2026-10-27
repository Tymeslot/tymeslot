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

  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  # The topic every user-registration event is published on.
  @user_registered_topic "auth:user_registered"

  @doc """
  Broadcasts a user registration event via PubSub.

  The event names the account and how it signed up, and nothing more: every
  subscriber in the node receives it, so it carries no credentials, contact
  details or request data. Whatever needs the sign-up's metadata gets it from
  the registration hook instead.

  ## Example
      Tymeslot.Infrastructure.PubSub.broadcast_user_registered(user)
  """
  @spec broadcast_user_registered(%{
          :id => term(),
          :provider => term(),
          optional(atom()) => term()
        }) ::
          :ok
  def broadcast_user_registered(%{id: user_id, provider: provider}) do
    message = {:user_registered, %{user_id: user_id, provider: provider}}

    case Phoenix.PubSub.broadcast(Tymeslot.PubSub, @user_registered_topic, message) do
      :ok ->
        Logger.info("Broadcasted user_registered event", user_id: user_id)

      {:error, reason} ->
        Logger.warning("Failed to broadcast user_registered event",
          reason: LogFormat.reason(reason)
        )
    end

    :ok
  end

  @doc """
  Subscribes the calling process to user-registration events.

  Every account that completes registration arrives in the caller's mailbox as
  `{:user_registered, %{user_id: user_id, provider: provider}}`. Returns
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

  @doc """
  Tells every LiveView of `user_id` that the account has been asked to be
  deleted, so a tab still showing its data leaves (see
  `TymeslotWeb.Hooks.AuthLiveSessionHook`). Delivered as
  `{:account_deletion_requested, user_id}`.
  """
  @spec broadcast_account_deletion_requested(pos_integer()) :: :ok
  def broadcast_account_deletion_requested(user_id) do
    case Phoenix.PubSub.broadcast(
           Tymeslot.PubSub,
           account_topic(user_id),
           {:account_deletion_requested, user_id}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to broadcast account deletion request",
          user_id: user_id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  @doc "Subscribes the calling process to events about one account."
  @spec subscribe_to_account(pos_integer()) :: :ok | {:error, term()}
  def subscribe_to_account(user_id),
    do: Phoenix.PubSub.subscribe(Tymeslot.PubSub, account_topic(user_id))

  defp account_topic(user_id), do: "auth:account:#{user_id}"
end
