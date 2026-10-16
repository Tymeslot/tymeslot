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
  alias TymeslotWeb.Dashboard.Calendar.DisplayPreferences
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.Calendar.Rail
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toolbar
  alias TymeslotWeb.Dashboard.Calendar.Visibility

  @menus %{"date" => :date, "display" => :display}

  # The parent's refresh messages (see `CalendarEventHandlers`): a sync
  # finished, events changed elsewhere, or a refresh fell back on its timer.
  @refresh_actions [:events_updated, :integration_synced, :refresh_events]

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, SurfaceData.defaults(socket)}

  @impl Phoenix.LiveComponent
  def update(%{action: action}, %{assigns: %{ready?: true}} = socket)
      when action in @refresh_actions,
      do: {:ok, SurfaceData.reload(socket)}

  def update(%{action: action}, socket) when action in @refresh_actions, do: {:ok, socket}

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
        density={@preferences.density}
        fold_night={@preferences.fold_night}
        rail_open={@rail_open}
        hidden_count={@hidden_count}
        target={@myself}
      />
      <div class="flex min-h-0 flex-1">
        <Rail.rail
          :if={@rail_open}
          accounts={@accounts}
          mini_cursor={@mini_cursor}
          view={@view}
          days={@days}
          today={@today}
          week_start={Period.week_start(@preferences.week_start_day)}
          locale={@locale}
          target={@myself}
        />
        <Canvas.canvas
          view={@view}
          date={@date}
          locale={@locale}
          strings={ClientStrings.build(@locale)}
          target={@myself}
        />
      </div>
      <Preview.preview :if={@preview} preview={@preview} target={@myself} />
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

  def handle_event("calendar:set_density", %{"option" => density}, socket),
    do: {:noreply, DisplayPreferences.set_density(socket, density)}

  def handle_event("calendar:toggle_fold_night", _params, socket),
    do: {:noreply, DisplayPreferences.toggle_fold_night(socket)}

  def handle_event("calendar:toggle_rail", _params, socket),
    do: {:noreply, assign(socket, :rail_open, !socket.assigns.rail_open)}

  def handle_event("calendar:toggle_account", %{"integration-id" => id}, socket),
    do: {:noreply, Visibility.toggle_account(socket, id)}

  def handle_event(
        "calendar:toggle_calendar",
        %{"integration-id" => id, "calendar-id" => calendar_id},
        socket
      ),
      do: {:noreply, Visibility.toggle_calendar(socket, id, calendar_id)}

  def handle_event("calendar:show_all", _params, socket),
    do: {:noreply, Visibility.show_all(socket)}

  # Only an event in the loaded window, which holds this organiser's events
  # alone, can be opened; anything else answers `opened: false`.
  def handle_event("calendar:open", %{"id" => id}, socket) when is_binary(id) do
    case Map.fetch(socket.assigns.events_by_id, id) do
      {:ok, event} ->
        preview = Preview.build(event, Preview.context(socket.assigns))
        {:reply, %{opened: true}, assign(socket, preview: preview, open_menu: nil)}

      :error ->
        {:reply, %{opened: false}, assign(socket, :preview, nil)}
    end
  end

  # Focus goes back to the event chip only for the Close button and Escape;
  # a click elsewhere (`refocus: "false"` from the click-away) keeps focus
  # where the organiser put it.
  def handle_event("calendar:close_preview", params, socket) do
    socket = assign(socket, :preview, nil)

    if Map.get(params, "refocus") == "false",
      do: {:noreply, socket},
      else: {:noreply, push_event(socket, "calendar:preview-closed", %{})}
  end
end
