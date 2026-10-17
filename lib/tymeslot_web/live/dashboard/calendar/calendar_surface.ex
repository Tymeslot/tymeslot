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
  alias TymeslotWeb.Dashboard.Calendar.DeleteConfirmModal
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.DisplayPreferences
  alias TymeslotWeb.Dashboard.Calendar.Manipulation
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.Calendar.Rail
  alias TymeslotWeb.Dashboard.Calendar.SeriesScopeModal
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.Toolbar
  alias TymeslotWeb.Dashboard.Calendar.Visibility
  alias TymeslotWeb.Dashboard.Calendar.Writes

  @reload_delay 250

  @menus %{"date" => :date, "display" => :display}

  # The parent's refresh messages (see `CalendarEventHandlers`): a sync
  # finished, events changed elsewhere, or a refresh fell back on its timer.
  @refresh_actions [:events_updated, :integration_synced, :refresh_events]

  # The mini month only pages within the years the grid can show.
  @mini_years 1900..2200

  # What each prompt can send; the module that acts on it parses it again.
  @timing_scopes ~w(this_only following all)
  @delete_scopes ~w(occurrence series)

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, SurfaceData.defaults(socket)}

  # A sync cycle sends several messages in a burst; they are coalesced into
  # one reload after `@reload_delay`. What the reload covers is the widest of
  # the actions asked for: `:events_updated` alone needs only the events.
  @impl Phoenix.LiveComponent
  def update(%{action: action}, %{assigns: %{ready?: true}} = socket)
      when action in @refresh_actions,
      do: {:ok, schedule_reload(socket, action)}

  def update(%{action: action}, socket) when action in @refresh_actions, do: {:ok, socket}

  def update(%{action: :reload}, %{assigns: %{pending_reload: scope}} = socket) do
    socket = assign(socket, :pending_reload, nil)

    if socket.assigns.ready? and scope,
      do: {:ok, SurfaceData.reload(socket, scope)},
      else: {:ok, socket}
  end

  # A write's answer, routed here by `CalendarRouting` (see `Writes`). A
  # failed write is taken back off the grid by the queue itself.
  def update(%{action: :event_write_settled, write: ref, outcome: outcome}, socket),
    do: {:ok, Writes.settle(socket, ref, outcome)}

  # A failed write is taken back off the grid by the queue; its change can
  # no longer be undone, and the toast that named it (not another event's)
  # gives way to the flash that says it failed.
  def update(%{action: :revert_event, write: {key, _seq} = ref}, socket),
    do:
      {:ok,
       socket |> Writes.settle(ref, :failed) |> Manipulation.forget(key) |> Toast.dismiss(key)}

  def update(%{action: :delete_settled, token: token, outcome: outcome}, socket),
    do: {:ok, Deletion.settled(socket, token, outcome)}

  def update(%{action: :toast_expired, toast: id}, socket), do: {:ok, Toast.expire(socket, id)}

  def update(%{action: :event_writes_released, release: release}, socket),
    do: {:ok, Writes.resume(socket, release)}

  # Messages for the old grid (an import's progress, a move between
  # calendars) reach whichever calendar is on screen; this one has nothing
  # to do with them.
  def update(%{action: _other}, socket), do: {:ok, socket}

  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> SurfaceData.sync()}

  defp schedule_reload(%{assigns: %{pending_reload: nil}} = socket, action) do
    send_update_after(__MODULE__, [id: socket.assigns.id, action: :reload], @reload_delay)
    assign(socket, :pending_reload, scope(action))
  end

  defp schedule_reload(%{assigns: %{pending_reload: scope}} = socket, action),
    do: assign(socket, :pending_reload, widest(scope, scope(action)))

  defp shift_mini_cursor(socket, dir) do
    cursor = Date.shift(socket.assigns.mini_cursor, month: step(dir))

    if cursor.year in @mini_years,
      do: assign(socket, :mini_cursor, cursor),
      else: socket
  end

  defp step(dir) when dir in [-1, "-1"], do: -1
  defp step(dir) when dir in [1, "1"], do: 1
  defp step(_dir), do: 0

  defp scope(:events_updated), do: :events
  defp scope(_action), do: :full

  defp widest(:full, _scope), do: :full
  defp widest(_scope, other), do: other

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
          date={@date}
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
      <Toast.toast toast={@toast} target={@myself} />
      <SeriesScopeModal.series_scope_modal
        :if={@series_prompt}
        prompt={@series_prompt}
        target={@myself}
      />
      <DeleteConfirmModal.delete_confirm_modal
        :if={@delete_prompt}
        prompt={@delete_prompt}
        target={@myself}
      />
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

  def handle_event("calendar:mini_shift", %{"dir" => dir}, socket),
    do: {:noreply, shift_mini_cursor(socket, dir)}

  def handle_event("calendar:set_density", %{"option" => density}, socket),
    do: {:noreply, DisplayPreferences.set_density(socket, density)}

  def handle_event("calendar:set_density", _params, socket), do: {:noreply, socket}

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

  def handle_event("calendar:move", params, socket),
    do: {:noreply, Manipulation.move(socket, params)}

  def handle_event("calendar:undo", _params, socket), do: {:noreply, Manipulation.undo(socket)}

  def handle_event("calendar:dismiss_toast", _params, socket),
    do: {:noreply, Toast.dismiss(socket)}

  # The scope is client input: only the scopes the open prompt offers are
  # acted on.
  def handle_event("calendar:choose_scope", %{"scope" => scope}, socket)
      when is_binary(scope) do
    case socket.assigns.series_prompt do
      %{kind: :timing} when scope in @timing_scopes ->
        {:noreply, Manipulation.choose_scope(socket, scope)}

      %{kind: :delete} when scope in @delete_scopes ->
        {:noreply, Deletion.choose_scope(socket, scope)}

      _none_or_not_offered ->
        {:noreply, socket}
    end
  end

  def handle_event("calendar:choose_scope", _params, socket), do: {:noreply, socket}

  def handle_event("calendar:cancel_scope", _params, socket),
    do: {:noreply, Manipulation.cancel_scope(socket)}

  def handle_event("calendar:delete", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, Deletion.request(socket, id)}

  def handle_event("calendar:delete", _params, socket), do: {:noreply, socket}

  def handle_event("calendar:confirm_delete", %{"notify" => notify}, socket)
      when is_binary(notify),
      do: {:noreply, Deletion.confirm(socket, notify)}

  def handle_event("calendar:confirm_delete", _params, socket), do: {:noreply, socket}

  def handle_event("calendar:cancel_delete", _params, socket),
    do: {:noreply, Deletion.cancel(socket)}

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
