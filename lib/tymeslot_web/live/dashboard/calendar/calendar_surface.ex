defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurface do
  @moduledoc """
  The calendar at `/dashboard/calendar` (see
  `ComponentDispatch.component_for_action/2`).

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
  alias TymeslotWeb.Dashboard.Calendar.BookableLayer
  alias TymeslotWeb.Dashboard.Calendar.BookingActions
  alias TymeslotWeb.Dashboard.Calendar.BookingMove
  alias TymeslotWeb.Dashboard.Calendar.CalendarColours
  alias TymeslotWeb.Dashboard.Calendar.CalendarsSheet
  alias TymeslotWeb.Dashboard.Calendar.Canvas
  alias TymeslotWeb.Dashboard.Calendar.ClientStrings
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.DateSheet
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.EventPanel
  alias TymeslotWeb.Dashboard.Calendar.IcsImport
  alias TymeslotWeb.Dashboard.Calendar.ImportModal
  alias TymeslotWeb.Dashboard.Calendar.LayerChoices
  alias TymeslotWeb.Dashboard.Calendar.Manipulation
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.PanelEvents
  alias TymeslotWeb.Dashboard.Calendar.PanelGuests
  alias TymeslotWeb.Dashboard.Calendar.PanelMeeting
  alias TymeslotWeb.Dashboard.Calendar.PanelNew
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PanelVideo
  alias TymeslotWeb.Dashboard.Calendar.PhoneHeader
  alias TymeslotWeb.Dashboard.Calendar.PhoneTabs
  alias TymeslotWeb.Dashboard.Calendar.PowerEvents
  alias TymeslotWeb.Dashboard.Calendar.PowerOverlays
  alias TymeslotWeb.Dashboard.Calendar.PowerSettings
  alias TymeslotWeb.Dashboard.Calendar.Preview
  alias TymeslotWeb.Dashboard.Calendar.Rail
  alias TymeslotWeb.Dashboard.Calendar.RailSets
  alias TymeslotWeb.Dashboard.Calendar.ReloadQueue
  alias TymeslotWeb.Dashboard.Calendar.ShortcutHelp
  alias TymeslotWeb.Dashboard.Calendar.SurfaceBookingEvents
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.SurfaceEventActions
  alias TymeslotWeb.Dashboard.Calendar.SurfaceMenus
  alias TymeslotWeb.Dashboard.Calendar.SurfaceModals
  alias TymeslotWeb.Dashboard.Calendar.SyncBanner
  alias TymeslotWeb.Dashboard.Calendar.SyncStatus
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.Toolbar
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.Calendar.ViewEvents
  alias TymeslotWeb.Dashboard.Calendar.Viewport
  alias TymeslotWeb.Dashboard.Calendar.Visibility
  alias TymeslotWeb.Dashboard.Calendar.Writes

  @reload_delay ReloadQueue.delay()

  # `calendar:*` events answered by `SurfaceBookingEvents` (every `booking:*`
  # event goes there too).
  @booking_events ~w(calendar:bookable_toggle calendar:bookable_type calendar:block calendar:open_booking calendar:bookability)

  # `calendar:*` events answered by `ViewEvents`: how a view is drawn.
  @view_events ~w(calendar:agenda_more calendar:viewport)

  # `calendar:*` events answered by `SurfaceMenus`: which menu is open and
  # which month the mini month shows.
  @menu_events ~w(calendar:toggle_menu calendar:close_menu calendar:mini_shift)

  # `calendar:*` events answered by `CalendarColours`: a calendar's own colour.
  @colour_events ~w(calendar:calendar_colour_open calendar:set_calendar_colour)

  # `calendar:*` events on one event or draft, answered by
  # `SurfaceEventActions`: open, edit, busy or free, create, More options,
  # the series question and delete.
  @event_actions ~w(calendar:open calendar:edit calendar:set_free calendar:create
    calendar:more_options calendar:choose_scope calendar:cancel_scope calendar:delete
    calendar:confirm_delete calendar:cancel_delete calendar:close_preview)

  @refresh_actions ReloadQueue.refresh_actions()

  @impl Phoenix.LiveComponent
  def mount(socket),
    do:
      {:ok,
       socket
       |> SurfaceData.defaults()
       |> BookingActions.defaults()
       |> PowerEvents.defaults()
       |> IcsImport.allow()}

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

  # A write's answer, routed here by `CalendarRouting` (see `Writes`).
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

  def update(
        %{action: :guests_pending_due, event_id: id, watch: watch, backoff: backoff},
        socket
      ),
      do: {:ok, PanelGuests.recheck_pending(socket, id, watch, backoff)}

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

  # A booking move started from the preview has answered (see `BookingMove`).
  def update(%{action: :booking_move_settled, meeting_id: id, result: result}, socket),
    do: {:ok, BookingMove.settled(socket, id, result)}

  def update(%{action: :toast_expired, toast: id}, socket), do: {:ok, Toast.expire(socket, id)}

  def update(%{action: :event_writes_released, release: release}, socket),
    do: {:ok, Writes.resume(socket, release)}

  # Meeting mode's answer, through the dashboard (see `PanelMeeting`); the
  # booking it made shows after the reload.
  def update(%{action: :ad_hoc_meeting_created, request: request}, socket),
    do: {:ok, socket |> PanelMeeting.created(request) |> schedule_reload(:events_updated)}

  def update(%{action: :ad_hoc_meeting_failed, request: request}, socket),
    do: {:ok, PanelMeeting.failed(socket, request)}

  # The power layer's actions go to `PowerEvents`; any other action this
  # surface has no clause for is ignored. Its lists are read at run time, so
  # the surface does not recompile with every module the power layer uses.
  def update(%{action: action} = message, socket) do
    if action in PowerEvents.update_actions(),
      do: {:ok, PowerEvents.update(message, socket)},
      else: {:ok, socket}
  end

  def update(assigns, socket),
    do:
      {:ok,
       socket
       |> PowerSettings.assign_parent(assigns)
       |> Viewport.adopt_hint()
       |> SurfaceData.sync()}

  defp schedule_reload(socket, action), do: ReloadQueue.schedule(socket, __MODULE__, action)

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

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assigns
      |> assign(SyncStatus.view(assigns))
      |> assign(
        locale: Gettext.get_locale(TymeslotWeb.Gettext),
        days: SurfaceData.days(assigns),
        panel_event: PanelState.current_event(assigns),
        panel_context: PanelState.context(assigns),
        set_view: RailSets.view(assigns)
      )

    ~H"""
    <div
      id="calendar-surface"
      class="relative flex min-h-0 flex-1 flex-col bg-white"
      phx-drop-target={@uploads.ics_file.ref}
    >
      <ImportModal.drop_zone uploads={@uploads} target={@myself} />
      <h1 class="sr-only">{dgettext("dashboard_calendar", "Calendar")}</h1>
      <ShortcutHelp.keys_hint />
      <%!-- Filled by the calendar hook (textContent); phx-update ignore keeps LiveView from clearing it. --%>
      <div id="calendar-live" class="sr-only" aria-live="polite" phx-update="ignore"></div>
      <Toolbar.toolbar
        week_numbers={@preferences.show_week_numbers}
        view={@view}
        date={@date}
        today={@today}
        days={@days}
        locale={@locale}
        open_menu={@open_menu}
        mini_cursor={@mini_cursor}
        week_start={Period.week_start(@preferences.week_start_day)}
        preferences={@preferences}
        desktop_permission={@desktop_permission}
        time_format={@time_format}
        rail_open={@rail_open}
        calendar_focus={@calendar_focus}
        hidden_count={@hidden_count}
        set_name={@set_view.name}
        target={@myself}
      />
      <PhoneHeader.phone_header
        view={@view}
        date={@date}
        days={@days}
        today={@today}
        locale={@locale}
        hidden_count={@hidden_count}
        set_name={@set_view.name}
        open_menu={@open_menu}
        target={@myself}
      />
      <SyncBanner.sync_banner problems={@sync_problems} syncing_ids={@syncing_ids} target={@myself} />
      <div class="cal-row relative isolate flex min-h-0 flex-1">
        <Rail.rail
          :if={@rail_open}
          week_numbers={@preferences.show_week_numbers}
          set_view={@set_view}
          accounts={@accounts}
          mini_cursor={@mini_cursor}
          view={@view}
          date={@date}
          days={@days}
          today={@today}
          week_start={Period.week_start(@preferences.week_start_day)}
          locale={@locale}
          syncing_ids={@syncing_ids}
          problem_ids={@problem_ids}
          reauth_ids={@reauth_ids}
          bookable={LayerChoices.rail(@preferences, @bookable_types)}
          colours={calendar_colours(assigns)}
          timezone={@timezone}
          target={@myself}
        />
        <Canvas.canvas
          view={@view}
          date={@date}
          days={@days}
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
          has_accounts={@accounts != []}
          integrations={@integrations}
          video_integrations={@video_integrations}
          guest_form_key={@guest_form_key}
          moving={not is_nil(@transfer)}
          group_allowed={assigns[:group_bookings_allowed] == true}
          timezone={@timezone}
          surface={@myself}
        />
      </div>
      <Preview.preview
        :if={@preview}
        preview={@preview}
        answering={@answering_request}
        moving={@moving_booking}
        target={@myself}
      />
      <CalendarsSheet.calendars_sheet
        :if={@open_menu == :calendars}
        accounts={@accounts}
        hidden_count={@hidden_count}
        set_view={@set_view}
        syncing_ids={@syncing_ids}
        problem_ids={@problem_ids}
        reauth_ids={@reauth_ids}
        bookable={LayerChoices.rail(@preferences, @bookable_types)}
        colours={calendar_colours(assigns)}
        preferences={@preferences}
        desktop_permission={@desktop_permission}
        time_format={@time_format}
        timezone={@timezone}
        target={@myself}
      />
      <DateSheet.date_sheet
        :if={@open_menu == :date_sheet}
        week_numbers={@preferences.show_week_numbers}
        mini_cursor={@mini_cursor}
        view={@view}
        date={@date}
        days={@days}
        today={@today}
        week_start={Period.week_start(@preferences.week_start_day)}
        locale={@locale}
        target={@myself}
      />
      <Toast.toast toast={@toast} target={@myself} />
      <PowerOverlays.overlays
        reminders_enabled={@preferences.desktop_reminders_enabled}
        reminder_feed={@reminder_feed}
        ics_import={@ics_import}
        uploads={@uploads}
        accounts={@accounts}
        open_menu={@open_menu}
        command={@command}
        target={@myself}
      />
      <SurfaceModals.modals
        series_prompt={@series_prompt}
        delete_prompt={@delete_prompt}
        series_move_prompt={@series_move_prompt}
        remove_guest_prompt={@remove_guest_prompt}
        discard_draft_prompt={@discard_draft_prompt}
        decline_request_modal_data={@decline_request_modal_data}
        cancel_meeting_modal_data={@cancel_meeting_modal_data}
        cancel_booking_payment={@cancel_booking_payment}
        cancel_seat_payments={@cancel_seat_payments}
        cancel_refund_error={@cancel_refund_error}
        cancel_refund_form={@cancel_refund_form}
        reschedule_request_modal_data={@reschedule_request_modal_data}
        calendar_move_modal_data={@calendar_move_modal_data}
        answering_request={@answering_request}
        sending_reschedule={@sending_reschedule}
        timezone={@timezone}
        time_format={@time_format}
        target={@myself}
      />
      <%!-- Last, in normal flow: the phone's tab bar (and the + button that floats above it). --%>
      <PhoneTabs.phone_tabs view={@view} date={@date} />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  # The reply carries the bookable layer as last pushed (nil until the first
  # load answers), so a hook mounted after that push still draws it. The
  # hook says whether it is on a phone first, so the reply's view is the one
  # that width shows (see `Viewport`), and names its browser tab, which may
  # take back an Undo (`Deletion.adopt_tab/2`).
  def handle_event("calendar:ready", params, socket) do
    socket =
      socket
      |> Viewport.report(params["phone"], false)
      |> Deletion.adopt_tab(params["tab"])

    {:reply,
     Map.put(SurfaceData.payload(socket.assigns, true), :bookable, socket.assigns.bookable),
     socket}
  end

  def handle_event("calendar:goto", %{"view" => view, "date" => date}, socket) do
    %{view: current_view, date: current_date} = socket.assigns

    path =
      Navigation.path(
        Period.parse_view(view, current_view),
        Period.parse_date(date, current_date)
      )

    {:noreply, push_patch(socket, to: path)}
  end

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

  def handle_event(event, params, socket) when event in @event_actions,
    do: SurfaceEventActions.handle(event, params, socket)

  # Everything the side panel sends (see `PanelEvents`).
  def handle_event("panel:" <> name, params, socket),
    do: {:noreply, PanelEvents.handle(name, params, socket)}

  # The preview's booking actions and the bookable layer's events (see
  # `SurfaceBookingEvents`).
  def handle_event("booking:" <> _name = event, params, socket),
    do: SurfaceBookingEvents.handle(event, params, socket)

  def handle_event(event, params, socket) when event in @booking_events,
    do: SurfaceBookingEvents.handle(event, params, socket)

  def handle_event(event, params, socket) when event in @menu_events,
    do: SurfaceMenus.handle(event, params, socket)

  def handle_event(event, params, socket) when event in @colour_events,
    do: CalendarColours.handle(event, params, socket)

  def handle_event(event, params, socket) when event in @view_events,
    do: ViewEvents.handle(event, params, socket)

  def handle_event("calendar:move", params, socket),
    do: {:noreply, Manipulation.move(socket, params)}

  def handle_event("calendar:undo", _params, socket), do: {:noreply, Manipulation.undo(socket)}

  def handle_event("calendar:dismiss_toast", _params, socket),
    do: {:noreply, Toast.dismiss(socket)}

  # Every other event is the power layer's (`PowerEvents.events/0`), read at
  # run time for the reason given above `update/2`'s last action clause.
  def handle_event(event, params, socket), do: PowerEvents.handle(event, params, socket)

  # Work run off this process (`start_async/3`): the import's file plan (see
  # `PowerEvents`), a request's answer and the bookable layer's load (see
  # `SurfaceBookingEvents`).
  @impl Phoenix.LiveComponent
  def handle_async(key, result, socket) do
    if key in PowerEvents.async_keys(),
      do: PowerEvents.async(key, result, socket),
      else: SurfaceBookingEvents.async(key, result, socket)
  end

  # What the calendar lists draw each calendar's colour picker from.
  defp calendar_colours(assigns),
    do: %{keys: assigns.calendar_colour_keys, open: assigns.calendar_colour_open}
end
