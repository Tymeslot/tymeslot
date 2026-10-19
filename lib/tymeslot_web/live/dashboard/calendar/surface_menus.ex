defmodule TymeslotWeb.Dashboard.Calendar.SurfaceMenus do
  @moduledoc """
  The calendar surface's menu state: which menu is open (`calendar:toggle_menu`,
  `calendar:close_menu`) and which month the mini month shows
  (`calendar:mini_shift`). `CalendarSurface` routes every event in its
  `@menu_events` here.

  The mini month follows the period, not the last month paged to: opening
  the toolbar's date picker or the phone's date sheet starts it on the
  period's month again.
  """

  import Phoenix.Component, only: [assign: 3]

  @type socket :: Phoenix.LiveView.Socket.t()

  @menus %{
    "date" => :date,
    "display" => :display,
    "calendars" => :calendars,
    "date_sheet" => :date_sheet
  }

  # The menus that show the mini month.
  @month_menus [:date, :date_sheet]

  # The mini month only pages within the years the grid can show.
  @mini_years 1900..2200

  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("calendar:toggle_menu", %{"menu" => menu}, socket) do
    wanted = Map.get(@menus, menu)
    open = if socket.assigns.open_menu == wanted, do: nil, else: wanted

    {:noreply, socket |> assign(:open_menu, open) |> follow_period(open)}
  end

  def handle("calendar:close_menu", _params, socket),
    do: {:noreply, assign(socket, :open_menu, nil)}

  def handle("calendar:mini_shift", %{"dir" => dir}, socket),
    do: {:noreply, shift_mini_cursor(socket, dir)}

  defp follow_period(socket, open) when open in @month_menus,
    do: assign(socket, :mini_cursor, Date.beginning_of_month(socket.assigns.date))

  defp follow_period(socket, _open), do: socket

  defp shift_mini_cursor(socket, dir) do
    cursor = Date.shift(socket.assigns.mini_cursor, month: step(dir))

    if cursor.year in @mini_years,
      do: assign(socket, :mini_cursor, cursor),
      else: socket
  end

  defp step(dir) when dir in [-1, "-1"], do: -1
  defp step(dir) when dir in [1, "1"], do: 1
  defp step(_dir), do: 0
end
