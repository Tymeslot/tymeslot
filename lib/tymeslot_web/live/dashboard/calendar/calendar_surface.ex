defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurface do
  @moduledoc """
  The redesigned calendar at `/dashboard/calendar`, rendered instead of
  `CalendarGridComponent` while the organiser's `redesign_enabled` switch is
  on (see `ComponentDispatch.component_for_action/3`).

  Rendering is split: this component owns the chrome (toolbar, rail,
  preview, display options) and every server round trip; the
  `CalendarCanvas` hook owns the time grid, drawn in the browser from the
  event JSON this component sends. The server stays the source of truth: the
  hook asks for data on mount (`calendar:ready`), and every change to what
  the grid shows pushes a fresh payload (`calendar:events`).

  URL state is `?view=&date=`, read from the `params` `DashboardLive` passes
  down on every `handle_params/3`.
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.Canvas
  alias TymeslotWeb.Dashboard.Calendar.ClientStrings
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toolbar

  @menus %{"date" => :date, "display" => :display}

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, SurfaceData.defaults(socket)}

  @impl Phoenix.LiveComponent
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> SurfaceData.sync()}

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        locale: Gettext.get_locale(TymeslotWeb.Gettext),
        days: SurfaceData.days(assigns)
      )

    ~H"""
    <div id="calendar-surface" class="flex min-h-0 flex-1 flex-col bg-white">
      <h1 class="sr-only">{dgettext("dashboard_calendar", "Calendar")}</h1>
      <Toolbar.toolbar
        view={@view}
        date={@date}
        today={@today}
        days={@days}
        locale={@locale}
        open_menu={@open_menu}
        mini_cursor={@mini_cursor}
        week_start={Period.week_start(@preferences.week_start_day)}
        target={@myself}
      />
      <div class="flex min-h-0 flex-1">
        <%!-- Rail --%>
        <Canvas.canvas
          view={@view}
          date={@date}
          locale={@locale}
          strings={ClientStrings.build(@locale)}
          target={@myself}
        />
      </div>
      <%!-- Preview --%>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("calendar:ready", _params, socket),
    do: {:reply, SurfaceData.payload(socket.assigns, true), socket}

  def handle_event("calendar:goto", %{"view" => view, "date" => date}, socket) do
    %{view: current_view, date: current_date} = socket.assigns

    path =
      Navigation.path(
        Period.parse_view(view, current_view),
        Period.parse_date(date, current_date)
      )

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("calendar:toggle_menu", %{"menu" => menu}, socket) do
    wanted = Map.get(@menus, menu)
    open = if socket.assigns.open_menu == wanted, do: nil, else: wanted

    {:noreply, assign(socket, :open_menu, open)}
  end

  def handle_event("calendar:close_menu", _params, socket),
    do: {:noreply, assign(socket, :open_menu, nil)}

  def handle_event("calendar:mini_shift", %{"dir" => dir}, socket) when dir in [-1, 1],
    do:
      {:noreply, assign(socket, :mini_cursor, Date.shift(socket.assigns.mini_cursor, month: dir))}
end
