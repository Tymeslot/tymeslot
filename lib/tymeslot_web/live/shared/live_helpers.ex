defmodule TymeslotWeb.Live.Shared.LiveHelpers do
  @moduledoc """
  Helper functions for LiveViews.
  These are functions that work with socket assigns, not components.
  """

  alias Tymeslot.Security.Security
  alias Tymeslot.Timezones

  # ========== TIMEZONE HELPERS ==========

  @doc """
  Validates a timezone and returns it in its canonical spelling (a legacy id
  such as `Asia/Calcutta` becomes `Asia/Kolkata`), or `:error` when it is not
  a timezone.
  """
  @spec resolve_timezone(term()) :: {:ok, String.t()} | :error
  def resolve_timezone(timezone) do
    case Security.validate_timezone(timezone) do
      {:ok, validated} -> {:ok, Timezones.normalize(validated)}
      {:error, _reason} -> :error
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
