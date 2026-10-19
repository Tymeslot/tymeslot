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

  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.Period
  alias Tymeslot.CalendarGrid.SyncProblems
  alias TymeslotWeb.Dashboard.Calendar.BookableLayer
  alias TymeslotWeb.Dashboard.Calendar.BookingActions
  alias TymeslotWeb.Dashboard.Calendar.BookingCancelModal
  alias TymeslotWeb.Dashboard.Calendar.BookingDeclineModal
  alias TymeslotWeb.Dashboard.Calendar.BookingRescheduleModal
  alias TymeslotWeb.Dashboard.Calendar.Canvas
  alias TymeslotWeb.Dashboard.Calendar.ClientStrings
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.DeleteConfirmModal
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.DisplayPreferences
  alias TymeslotWeb.Dashboard.Calendar.EventPanel
  alias TymeslotWeb.Dashboard.Calendar.FreeBusy
  alias TymeslotWeb.Dashboard.Calendar.LayerChoices
  alias TymeslotWeb.Dashboard.Calendar.Manipulation
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.PanelEvents
  alias TymeslotWeb.Dashboard.Calendar.PanelNew
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PanelVideo
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.Calendar.Rail
  alias TymeslotWeb.Dashboard.Calendar.RemoveGuestModal
  alias TymeslotWeb.Dashboard.Calendar.SeriesMoveModal
  alias TymeslotWeb.Dashboard.Calendar.SeriesScopeModal
  alias TymeslotWeb.Dashboard.Calendar.SurfaceBookingEvents
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.SyncBanner
  alias TymeslotWeb.Dashboard.Calendar.SyncStatus
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.Toolbar
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.Calendar.Visibility
  alias TymeslotWeb.Dashboard.Calendar.Writes

  @reload_delay 250

  # `calendar:*` events answered by `SurfaceBookingEvents` (every `booking:*`
  # event goes there too).
  @booking_events ~w(calendar:bookable_toggle calendar:bookable_type calendar:block calendar:open_booking calendar:bookability)

  @menus %{"date" => :date, "display" => :display}

  # The parent's refresh messages (see `CalendarEventHandlers`): a sync
  # finished, events changed elsewhere, or a refresh fell back on its timer.
  @refresh_actions [:events_updated, :integration_synced, :refresh_events]

  # The mini month only pages within the years the grid can show.
  @mini_years 1900..2200

  # What each prompt can send; the module that acts on it parses it again.
  @timing_scopes ~w(this_only following all)
  @delete_scopes ~w(occurrence series)
  @repeat_scopes ~w(following all)

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, socket |> SurfaceData.defaults() |> BookingActions.defaults()}

  # A sync cycle sends several messages in a burst; they are coalesced into
  # one reload after `@reload_delay`. What the reload covers is the widest of
  # the actions asked for: `:events_updated` alone needs only the events.
  @impl Phoenix.LiveComponent
  def update(%{action: action} = assigns, %{assigns: %{ready?: true}} = socket)
      when action in @refresh_actions,
      do:
        {:ok, socket |> SyncStatus.finished(assigns[:integration_id]) |> schedule_reload(action)}

  # One failed attempt (see `SyncStatus`). The whole context is reloaded as
  # after a sync: a discard for rejected credentials flags the integration
  # `needs_reauth`, which the banner must show while the calendar is open.
  def update(
        %{action: :integration_sync_failed, integration_id: id},
        %{assigns: %{ready?: true}} = socket
      ),
      do: {:ok, failed_sync(socket, id)}

  def update(%{action: :sync_timeout, integration_id: id, ref: ref}, socket),
    do: {:ok, SyncStatus.timed_out(socket, id, ref)}

  def update(%{action: action}, socket) when action in @refresh_actions, do: {:ok, socket}

  def update(%{action: :reload}, %{assigns: %{pending_reload: scope}} = socket) do
    socket = assign(socket, :pending_reload, nil)

    if socket.assigns.ready? and scope,
      do: {:ok, SurfaceData.reload(socket, scope)},
      else: {:ok, socket}
  end

  # The organiser's availability changed (`CalendarRouting.bookable_changed/1`).
  # A schedule edit or a booking can broadcast several times in a row; they
  # are coalesced into one reload of the layer after `@reload_delay`.
  def update(%{action: :bookable_changed}, %{assigns: %{ready?: true}} = socket),
    do: {:ok, schedule_bookable(socket)}

  def update(%{action: :bookable_reload}, socket),
    do: {:ok, socket |> assign(:bookable_pending, false) |> BookableLayer.reload()}

  # A write's answer, routed here by `CalendarRouting` (see `Writes`). A
  # failed write is taken back off the grid by the queue itself.
  def update(%{action: :event_write_settled, write: ref, outcome: outcome}, socket),
    do:
      {:ok,
       socket
       |> Writes.settle(ref, outcome)
       |> Manipulation.settled(ref)
       |> PanelEdits.settled(ref, outcome)
       |> unchanged_video(ref, outcome)
       |> reload_if_queued(outcome)}

  # A video change landed (see `PanelVideo`).
  def update(%{action: :video_link_updated, write: ref, updated_event: updated}, socket),
    do: {:ok, PanelVideo.settled(socket, ref, updated)}

  # A failed write is taken back off the grid by the queue; its change can
  # no longer be undone, and the toast that named it (not another event's)
  # gives way to the flash that says it failed.
  def update(%{action: :revert_event, write: {key, _seq} = ref}, socket),
    do:
      {:ok,
       socket
       |> Writes.settle(ref, :failed)
       |> Manipulation.forget(ref)
       |> PanelEdits.settled(ref, :failed)
       |> PanelVideo.reverted(key)
       |> Toast.dismiss(key)}

  # A move to another calendar answering (see `Transfer`); a failed single
  # move is a revert that names no write.
  def update(%{action: :revert_event, original_event: %{} = event}, socket),
    do: {:ok, Transfer.failed(socket, event)}

  def update(%{action: :event_moved} = moved, socket), do: {:ok, Transfer.moved(socket, moved)}

  def update(%{action: :series_moved, moved_event: event} = moved, socket),
    do: {:ok, Transfer.series_moved(socket, event, moved[:source])}

  def update(%{action: :series_move_failed, moved_event: event}, socket),
    do: {:ok, Transfer.series_failed(socket, event)}

  def update(%{action: :delete_settled, token: token, outcome: outcome}, socket),
    do: {:ok, Deletion.settled(socket, token, outcome)}

  # Another tab scheduled or undid a delete (see `Deletion`).
  def update(%{action: :delete_scheduled, token: token, address: address, scope: scope}, socket),
    do: {:ok, Deletion.scheduled_elsewhere(socket, token, address, scope)}

  def update(%{action: :delete_cancelled, token: token}, socket),
    do: {:ok, Deletion.cancelled(socket, token)}

  # A create this surface started has answered (see `Creation`). A surface
  # mounted since, not yet loaded, has nothing to reload.
  def update(
        %{action: :create_settled, draft: draft, title: title, result: result},
        %{assigns: %{ready?: true}} = socket
      ),
      do:
        {:ok, socket |> Creation.settled(draft, title, result) |> PanelNew.settled(draft, result)}

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

  defp schedule_bookable(%{assigns: %{bookable_pending: true}} = socket), do: socket

  defp schedule_bookable(socket) do
    send_update_after(
      __MODULE__,
      [id: socket.assigns.id, action: :bookable_reload],
      @reload_delay
    )

    assign(socket, :bookable_pending, true)
  end

  defp failed_sync(socket, id) do
    case SyncStatus.failed(socket, id) do
      {:ok, socket} -> schedule_reload(socket, :integration_synced)
      :unknown -> socket
    end
  end

  # A write saved for later leaves its event waiting to be sent, which the
  # sync banner names, so the loaded events must show that state. The price
  # is one events query per queued write (coalesced with any other reload
  # within `@reload_delay`); patching the one event in place would need to
  # know the sync state the queue stored, which only the database holds.
  defp reload_if_queued(%{assigns: %{ready?: true}} = socket, :queued),
    do: schedule_reload(socket, :events_updated)

  defp reload_if_queued(socket, _outcome), do: socket

  # A video change that changed nothing (see `PanelVideo.unchanged/2`).
  defp unchanged_video(socket, ref, :unchanged), do: PanelVideo.unchanged(socket, ref)
  defp unchanged_video(socket, _ref, _outcome), do: socket

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
        days: SurfaceData.days(assigns),
        panel_event: PanelState.current_event(assigns),
        panel_context: PanelState.context(assigns),
        sync_problems:
          SyncProblems.list(
            assigns.integrations,
            assigns.window_events,
            SyncStatus.failed_ids(assigns)
          )
      )

    ~H"""
    <div id="calendar-surface" class="flex min-h-0 flex-1 flex-col bg-white">
      <h1 class="sr-only">{dgettext("dashboard_calendar", "Calendar")}</h1>
      <p id="calendar-keys-hint" class="sr-only">
        {dgettext(
          "dashboard_calendar",
          "Arrow keys move between events. Press C to add an event at the next free time. Press Enter to open the focused event, E to edit it, and M to move it: arrow keys then shift it, Shift with the arrow keys changes its length, Enter confirms and Escape cancels. Press Delete to delete the event and Ctrl Z (Cmd Z on a Mac) to undo."
        )}
        {dgettext("dashboard_calendar_booking", "Press B to show or hide your bookable times.")}
      </p>
      <%!-- Filled by the calendar hook (textContent); phx-update ignore keeps LiveView from clearing it. --%>
      <div id="calendar-live" class="sr-only" aria-live="polite" phx-update="ignore"></div>
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
      <SyncBanner.sync_banner problems={@sync_problems} syncing_ids={@syncing_ids} target={@myself} />
      <div class="relative isolate flex min-h-0 flex-1">
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
          syncing_ids={@syncing_ids}
          problem_ids={MapSet.new(@sync_problems, & &1.integration_id)}
          reauth_ids={MapSet.new(for(%{needs_reauth: true, id: id} <- @integrations, do: id))}
          bookable={LayerChoices.rail(@preferences, @bookable_types)}
          target={@myself}
        />
        <Canvas.canvas
          view={@view}
          date={@date}
          locale={@locale}
          strings={ClientStrings.build(@locale)}
          target={@myself}
        />
        <.live_component
          :if={@panel}
          module={EventPanel}
          id="calendar-panel"
          panel={@panel}
          event={@panel_event}
          context={@panel_context}
          calendar_choices={CalendarDirectory.choices(@accounts)}
          video_integrations={@video_integrations}
          guest_form_key={@guest_form_key}
          moving={not is_nil(@transfer)}
          surface={@myself}
        />
      </div>
      <Preview.preview
        :if={@preview}
        preview={@preview}
        answering={@answering_request}
        target={@myself}
      />
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
      <SeriesMoveModal.series_move_modal
        :if={@series_move_prompt}
        prompt={@series_move_prompt}
        target={@myself}
      />
      <RemoveGuestModal.remove_guest_modal
        :if={@remove_guest_prompt}
        prompt={@remove_guest_prompt}
        target={@myself}
      />
      <BookingDeclineModal.booking_decline_modal
        :if={@decline_request_modal_data}
        meeting={@decline_request_modal_data}
        declining={not is_nil(@answering_request)}
        timezone={@timezone}
        time_format={@time_format}
        target={@myself}
      />
      <BookingCancelModal.booking_cancel_modal
        :if={@cancel_meeting_modal_data}
        meeting={@cancel_meeting_modal_data}
        booking_payment={@cancel_booking_payment}
        timezone={@timezone}
        time_format={@time_format}
        target={@myself}
      />
      <BookingRescheduleModal.booking_reschedule_modal
        :if={@reschedule_request_modal_data}
        meeting={@reschedule_request_modal_data}
        sending={not is_nil(@sending_reschedule)}
        timezone={@timezone}
        time_format={@time_format}
        target={@myself}
      />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  # The reply carries the bookable layer as last pushed (nil until the first
  # load answers), so a hook mounted after that push still draws it.
  def handle_event("calendar:ready", _params, socket),
    do:
      {:reply,
       Map.put(SurfaceData.payload(socket.assigns, true), :bookable, socket.assigns.bookable),
       socket}

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

  def handle_event("calendar:sync_account", %{"integration-id" => id}, socket),
    do: {:noreply, SyncStatus.sync_account(socket, id)}

  # Only an event in the loaded window, which holds this organiser's events
  # alone, can be opened; anything else answers `opened: false`.
  def handle_event("calendar:open", %{"id" => id}, socket) when is_binary(id) do
    case Map.fetch(socket.assigns.events_by_id, id) do
      {:ok, event} ->
        preview = Preview.build(event, Preview.context(socket.assigns))

        {:reply, %{opened: true},
         socket |> PanelState.give_way() |> assign(preview: preview, open_menu: nil)}

      :error ->
        {:reply, %{opened: false}, assign(socket, :preview, nil)}
    end
  end

  # Opens the side panel on a loaded event: from the hook (E on a focused
  # event) or the preview's Edit button.
  def handle_event("calendar:edit", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, PanelState.open_edit(socket, id)}

  def handle_event("calendar:edit", _params, socket), do: {:noreply, socket}

  def handle_event("calendar:set_free", %{"id" => id, "free" => free}, socket)
      when is_binary(id) and free in ["true", "false"],
      do: {:noreply, FreeBusy.set(socket, id, free == "true")}

  def handle_event("calendar:set_free", _params, socket), do: {:noreply, socket}

  # Everything the side panel sends (see `PanelEvents`).
  def handle_event("panel:" <> name, params, socket),
    do: {:noreply, PanelEvents.handle(name, params, socket)}

  # The preview's booking actions and the bookable layer's events (see
  # `SurfaceBookingEvents`).
  def handle_event("booking:" <> _name = event, params, socket),
    do: SurfaceBookingEvents.handle(event, params, socket)

  def handle_event(event, params, socket) when event in @booking_events,
    do: SurfaceBookingEvents.handle(event, params, socket)

  def handle_event("calendar:move", params, socket),
    do: {:noreply, Manipulation.move(socket, params)}

  # The reply tells the hook whether its draft was accepted, or which field
  # was refused and why (see `Creation`).
  def handle_event("calendar:create", params, socket) do
    {reply, socket} = Creation.create(socket, params)
    {:reply, reply, socket}
  end

  # Quick create's More options: the panel opens in its New event state on
  # the draft (see `PanelNew`); the hook keeps drawing it until the payload.
  # Every path replies, so the popover never waits on its timeout.
  def handle_event("calendar:more_options", params, socket) do
    {opened, socket} = PanelNew.open(socket, params)
    {:reply, %{opened: opened}, socket}
  end

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

      %{kind: :panel} when scope in @timing_scopes ->
        {:noreply, PanelEdits.choose_scope(socket, scope)}

      %{kind: :panel_repeat} when scope in @repeat_scopes ->
        {:noreply, PanelEdits.choose_scope(socket, scope)}

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

  # Work run off this process (`start_async/3`): a request's answer and the
  # bookable layer's load (see `SurfaceBookingEvents`).
  @impl Phoenix.LiveComponent
  def handle_async(key, result, socket), do: SurfaceBookingEvents.async(key, result, socket)
end
