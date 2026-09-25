defmodule TymeslotWeb.Live.Shared.LiveHelpers do
  @moduledoc """
  Helper functions for LiveViews.
  These are functions that work with socket assigns, not components.
  """
  import Phoenix.Component

  alias Tymeslot.Security.Security
  alias Tymeslot.Timezones

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
