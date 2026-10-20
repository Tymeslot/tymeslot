defmodule TymeslotWeb.Dashboard.Calendar.SurfaceMenus do
  @moduledoc """
  The calendar surface's menu state: which menu is open (`calendar:toggle_menu`,
  `calendar:close_menu`) and which month the mini month shows
  (`calendar:mini_shift`). `CalendarSurface` routes every event in its
  `@menu_events` here.

  The shortcut help (`ShortcutHelp`) is the `:shortcuts` menu, so any other menu
  replaces it.

  The mini month follows the period, not the last month paged to: opening
  the toolbar's date picker or the phone's date sheet starts it on the
  period's month again.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  @type socket :: Phoenix.LiveView.Socket.t()

  @menus %{
    "date" => :date,
    "display" => :display,
    "calendars" => :calendars,
    "date_sheet" => :date_sheet,
    "shortcuts" => :shortcuts
  }

  # The menus that open as modals or sheets over the grid.
  @modal_menus [:shortcuts, :calendars, :date_sheet]

  # The menus that show the mini month.
  @month_menus [:date, :date_sheet]

  # The mini month only pages within the years the grid can show.
  @mini_years 1900..2200

  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("calendar:toggle_menu", %{"menu" => menu} = params, socket) do
    wanted = Map.get(@menus, menu)
    open = if socket.assigns.open_menu == wanted, do: nil, else: wanted

    {:noreply,
     socket
     |> assign(:open_menu, open)
     |> close_preview_for(open)
     |> follow_period(open)
     |> mark_return(params)}
  end

  def handle("calendar:close_menu", _params, socket),
    do: {:noreply, socket |> assign(:open_menu, nil) |> restore_focus()}

  def handle("calendar:mini_shift", %{"dir" => dir}, socket),
    do: {:noreply, shift_mini_cursor(socket, dir)}

  # A modal opened over the preview would share its Escape key, so the preview
  # gives way, as opening the preview closes any menu.
  defp close_preview_for(socket, menu) when menu in @modal_menus,
    do: assign(socket, :preview, nil)

  defp close_preview_for(socket, _menu), do: socket

  @doc """
  Notes whether the menu or modal being opened came from the display options
  (`"return" => "display"`): that dropdown or sheet goes away with the click,
  and with it the focused button.
  """
  @spec mark_return(socket(), map()) :: socket()
  def mark_return(socket, params),
    do: assign(socket, :focus_return, params["return"] == "display")

  @doc """
  When what the display options opened closes, hands focus back to the
  control that leads to them: the toolbar's toggle, or the phone's Calendars
  button. Anything opened by a key keeps the modal focus trap's own restore.
  """
  @spec restore_focus(socket()) :: socket()
  def restore_focus(%{assigns: %{focus_return: true}} = socket) do
    socket
    |> assign(:focus_return, false)
    |> push_event("calendar:focus", %{
      ids: ["calendar-display-toggle", "calendar-phone-calendars"]
    })
  end

  def restore_focus(socket), do: socket

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
