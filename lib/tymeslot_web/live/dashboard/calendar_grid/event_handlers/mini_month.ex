defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.MiniMonth do
  @moduledoc """
  Event handlers for the mini-month date-picker popover.

  The popover is a self-contained month grid hung off the toolbar period label.
  Stepping its prev/next arrows moves the `mini_month_cursor` (the displayed
  picker month) without touching the main grid's `date`. Picking a day reuses
  the existing `navigate_to_day` flow; the popover open/close mirrors the
  calendar-list dropdown pattern.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_mini_month", _params, socket) do
    opening = !socket.assigns.mini_month_open

    {:noreply,
     socket
     |> assign(:mini_month_open, opening)
     |> assign(:mini_month_cursor, if(opening, do: socket.assigns.date, else: nil))
     |> assign(:show_calendar_list, false)
     |> assign(:show_view_menu, false)}
  end

  def handle_event("close_mini_month", _params, socket), do: {:noreply, close(socket)}
  def handle_event("mini_month_prev", _params, socket), do: {:noreply, step_cursor(socket, -1)}
  def handle_event("mini_month_next", _params, socket), do: {:noreply, step_cursor(socket, 1)}

  @doc """
  Closes the popover and clears the picker cursor. Called by `navigate_to_day`
  after the main grid has jumped to the picked day.
  """
  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> assign(:mini_month_open, false)
    |> assign(:mini_month_cursor, nil)
  end

  defp step_cursor(socket, delta) do
    cursor = socket.assigns.mini_month_cursor || socket.assigns.date
    assign(socket, :mini_month_cursor, Helpers.navigate_month(cursor, delta))
  end
end
