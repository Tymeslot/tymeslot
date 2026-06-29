defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shortcuts do
  @moduledoc "Keyboard-shortcut event handlers for CalendarGridComponent (presentation layer)."

  import Phoenix.Component, only: [assign: 3]

  @spec handle_toggle_shortcuts_help(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_shortcuts_help(_params, socket) do
    {:noreply, assign(socket, :show_shortcuts_help, not socket.assigns.show_shortcuts_help)}
  end
end
