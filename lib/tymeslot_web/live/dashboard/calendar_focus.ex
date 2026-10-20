defmodule TymeslotWeb.Dashboard.CalendarFocus do
  @moduledoc """
  Focus mode for the calendar: the dashboard menu goes, so the calendar
  takes the screen. The choice is the organiser's `focus_mode` preference,
  which `DashboardLive` reads on the calendar's first open and keeps
  in `calendar_focus`; the layout lives in `DashboardLive`, so the calendar's
  toggles (toolbar, display options, F) are handled there, not in the
  calendar component.

  Focus applies only on the calendar and gives way while the product
  tour runs, because the tour points at the menu. Below 1024px the menu is
  already a drawer, so the stylesheet hides it from `lg` only.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tymeslot.CalendarGrid

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Turns focus mode the other way and saves it; a failed save leaves it and says so."
  @spec toggle(socket()) :: socket()
  def toggle(%{assigns: %{current_user: %{id: user_id}}} = socket) do
    focus = socket.assigns[:calendar_focus] != true

    case CalendarGrid.save_preferences(user_id, %{focus_mode: focus}) do
      {:ok, _preferences} ->
        assign(socket, :calendar_focus, focus)

      {:error, _changeset} ->
        put_flash(
          socket,
          :error,
          dgettext("dashboard_calendar_power", "Couldn't change focus mode. Please try again.")
        )
    end
  end

  @doc """
  Whether the page is in focus mode now: on the calendar, with focus chosen
  and no tour running.
  """
  @spec active?(map()) :: boolean()
  def active?(assigns) do
    assigns[:live_action] == :calendar and assigns[:calendar_focus] == true and
      assigns[:tour_active] != true
  end
end
