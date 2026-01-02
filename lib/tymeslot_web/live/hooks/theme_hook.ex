defmodule TymeslotWeb.Hooks.ThemeHook do
  @moduledoc """
  LiveView hook to handle theme assignment for scheduling and meeting management pages.
  Sets the theme_id in assigns before the layout renders.
  """

  import Phoenix.Component

  alias Tymeslot.Profiles

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, _session, socket) do
    theme_id = extract_theme_id(params, socket)
    {:cont, assign(socket, :theme_id, theme_id)}
  end

  defp extract_theme_id(params, socket) do
    cond do
      # Check for explicit theme parameter
      params["theme"] ->
        params["theme"]

      # Check if theme_id is in params (debug routes)
      params["theme_id"] ->
        params["theme_id"]

      # For username-based routes, resolve from profile
      params["username"] ->
        case Profiles.get_profile_by_username(params["username"]) do
          %{booking_theme: theme} when not is_nil(theme) -> theme
          _ -> "1"
        end

      # Check if it's in socket.private (from router)
      socket.private[:theme_id] ->
        socket.private[:theme_id]

      # Default to theme 1
      true ->
        "1"
    end
  end
end
