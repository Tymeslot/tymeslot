defmodule TymeslotWeb.Live.Shared.LiveHelpers do
  @moduledoc """
  Helper functions for LiveViews.
  These are functions that work with socket assigns, not components.
  """
  import Phoenix.Component

  alias Tymeslot.Auth.Authentication
  alias Tymeslot.Security.Security
  alias Tymeslot.Timezones

  # ========== USER HELPERS ==========

  @doc """
  Assigns the current user to the socket based on session token.

  If a valid user_token exists in the session, fetches and assigns the user.
  Otherwise, assigns nil to current_user.
  """
  @spec assign_current_user(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_current_user(socket, session) do
    case session do
      %{"user_token" => user_token} when is_binary(user_token) ->
        user = Authentication.get_user_by_session_token(user_token)
        assign(socket, :current_user, user)

      _other ->
        assign(socket, :current_user, nil)
    end
  end

  # ========== TIMEZONE HELPERS ==========

  @doc """
  Validates and updates timezone on the socket.
  """
  @spec update_timezone(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def update_timezone(socket, new_timezone) do
    case Security.validate_timezone(new_timezone) do
      {:ok, validated} ->
        # Normalize timezone to ensure consistency
        normalized_timezone = Timezones.normalize(validated)
        assign(socket, :user_timezone, normalized_timezone)

      {:error, _reason} ->
        socket
    end
  end

  # ========== UTILITY HELPERS ==========

  @doc """
  Shorthand for {:ok, socket} returns.
  """
  @spec ok(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def ok(socket), do: {:ok, socket}

  @doc """
  Shorthand for {:noreply, socket} returns.
  """
  @spec noreply(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def noreply(socket), do: {:noreply, socket}
end
