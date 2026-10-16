defmodule TymeslotWeb.Themes.Shared.EventHandlers do
  @moduledoc """
  Page-level events a scheduling page handles outside the booking steps: the
  language switcher and the timezone search box.
  """

  alias Phoenix.LiveView
  alias TymeslotWeb.Themes.Shared.LiveHelpers.Tracking
  import Phoenix.Component, only: [assign: 3]

  @doc """
  Handles toggling the language dropdown.
  """
  @spec handle_toggle_language_dropdown(LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_toggle_language_dropdown(socket) do
    {:noreply, assign(socket, :language_dropdown_open, !socket.assigns.language_dropdown_open)}
  end

  @doc """
  Handles closing the language dropdown.
  """
  @spec handle_close_language_dropdown(LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_close_language_dropdown(socket) do
    {:noreply, assign(socket, :language_dropdown_open, false)}
  end

  @doc """
  Handles locale change with a full page redirect to ensure the session is updated.
  Using a full redirect (external: true) is necessary because session updates
  can only happen over HTTP, not via WebSocket/LiveView client-side navigation.
  """
  @spec handle_change_locale(LiveView.Socket.t(), String.t(), module()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_change_locale(socket, locale, path_handlers_module) do
    path =
      socket
      |> path_handlers_module.build_path_with_locale(locale)
      |> Tracking.tracking_path(socket.assigns[:tracking])

    {:noreply, LiveView.redirect(socket, external: path)}
  end

  @doc """
  Handles timezone search input updates.
  """
  @spec handle_timezone_search(LiveView.Socket.t(), map()) :: {:noreply, LiveView.Socket.t()}
  def handle_timezone_search(socket, params) do
    search_term =
      case params do
        %{"search" => term} -> term
        %{"value" => term} -> term
        %{"_target" => ["search"], "search" => term} -> term
        _other -> ""
      end

    socket =
      socket
      |> assign(:timezone_search, search_term)
      |> assign(:timezone_dropdown_open, true)

    {:noreply, socket}
  end
end
