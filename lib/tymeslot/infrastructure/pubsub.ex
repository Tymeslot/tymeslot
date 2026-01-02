defmodule Tymeslot.Infrastructure.PubSub do
  @moduledoc """
  Handles PubSub broadcasting for auth-related events.

  This module provides a centralized way to broadcast authentication events
  within the Tymeslot application.
  """
  require Logger

  @doc """
  Broadcasts a user registration event via PubSub.

  ## Parameters
  - `user`: The newly registered user struct
  - `metadata`: Optional map of additional data (default: %{})

  ## Example
      Tymeslot.Infrastructure.PubSub.broadcast_user_registered(user, %{source: "signup"})
  """
  @spec broadcast_user_registered(struct(), map()) :: :ok
  def broadcast_user_registered(user, metadata \\ %{}) do
    message = {:user_registered, %{user: user, metadata: metadata}}

    case Phoenix.PubSub.broadcast(Tymeslot.PubSub, "auth:user_registered", message) do
      :ok ->
        Logger.info("Broadcasted user_registered event for user_id=#{user.id}")

      {:error, reason} ->
        Logger.warning("Failed to broadcast user_registered event: #{inspect(reason)}")
    end

    :ok
  end
end
