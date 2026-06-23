defmodule TymeslotWeb.Dashboard.CalendarGridComponent do
  @moduledoc """
  LiveComponent rendering a week/day/month calendar grid backed by cached calendar events.

  ## Public API

  The parent LiveView passes the following assigns. The two that are component-specific
  are declared as `attr` below for documentation purposes; the remainder are forwarded
  from the dashboard's generic component dispatch pattern and stored via
  `UpdateHandlers.handle_initial/2`.

  Note: the call site uses a dynamic `module={@component_module}` reference, so Phoenix
  cannot perform compile-time `attr` validation. Moving to a static module reference
  would enable that check.

  Component-specific assigns (declared as `attr`):
  - `:current_user` — required, owns the calendar preferences and integrations.
  - `:profile`      — optional, only its `:timezone` field is read.

  Additional assigns forwarded from the parent dashboard LiveView:
  - `:shared_data`               — map of shared cross-component data, defaults to `%{}`.
  - `:integration_status`        — current calendar integration status.
  - `:saving`                    — boolean, whether the parent is persisting something.
  - `:client_ip`                 — client IP string, used for audit / rate-limit context.
  - `:user_agent`                — client user-agent string.
  - `:live_action`               — current route live action atom.
  - `:params`                    — current URL params map.
  - `:custom_questions_allowed`  — boolean feature flag.

  Parent-to-component messages travel through `send_update/2` with an `:action` key.
  These bypass attr validation and are dispatched in the `update/2` clauses below:
  `:revert_event`, `:refresh_events`, `:reload_events`, `:ad_hoc_meeting_created`,
  `:ad_hoc_meeting_failed`, `:event_created`, `:event_create_failed`, `:event_moved`,
  `:event_deleted`, `:event_delete_failed`, `:events_updated`, `:video_link_updated`,
  `:integration_synced`.

  ## Internal state

  Initialised in `mount/1` and mutated by handlers — not part of the public API:
  `:view`, `:date`, `:events`, `:integrations`, `:integration_colors`, `:loading`,
  `:selected_event`, `:current_time`, `:hidden_integration_ids`, `:preferences`,
  plus modal/menu visibility flags and sync-progress counters.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Meetings
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.AttendeeManagement
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.DragDrop
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCrud
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.InlineEdit
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Navigation
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.NotificationFlows
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Preferences
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Visibility
  alias TymeslotWeb.Dashboard.CalendarGrid.GridViews
  alias TymeslotWeb.Dashboard.CalendarGrid.Header
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDeleteModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDiscardAttendeesModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmRemoveAttendeeModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.CreateEventModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.EventDetailModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.NotifyPromptModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModal
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.SettingsModal
  alias TymeslotWeb.Dashboard.CalendarGrid.UpdateHandlers

  attr :current_user, :map, required: true, doc: "Owns calendar preferences and integrations."

  attr :profile, :any,
    default: nil,
    doc: "Profile struct or nil; only `:timezone` is read."

  @impl Phoenix.LiveComponent
  def mount(socket) do
    socket =
      socket
      |> assign(:view, :week)
      |> assign(:date, Date.utc_today())
      |> assign(:events, [])
      |> assign(:integrations, [])
      |> assign(:integration_colors, %{})
      |> assign(:loading, false)
      |> assign(:selected_event, nil)
      |> assign(:current_time, DateTime.utc_now())
      |> assign(:hidden_integration_ids, [])
      |> assign(:preferences, nil)
      |> assign(:show_calendar_list, false)
      |> assign(:show_view_menu, false)
      |> assign(:show_settings, false)
      |> assign(:creating_event, nil)
      |> assign(:recurrence_prompt, nil)
      |> assign(:confirm_delete_event, nil)
      |> assign(:confirm_delete_linked_to_booking, false)
      |> assign(:saving_event, false)
      |> assign(:deleting_event, false)
      |> assign(:video_integrations, [])
      |> assign(:confirm_remove_attendee, nil)
      |> assign(:pending_attendees, [])
      |> assign(:confirm_discard_attendees, false)
      |> assign(:attendee_input, "")
      |> assign(:notify_prompt, nil)
      |> assign(:pending_notification, false)
      |> assign(:owned_integration_ids, MapSet.new())
      |> assign(:visible_events, [])
      |> assign(:guest_rsvp_summaries, %{})
      |> assign(:visible_days, [])
      |> assign(:user_timezone, "UTC")
      |> assign(:timezone_display, "UTC")
      |> assign(:timezone_country_code, nil)
      |> assign(:syncing, false)
      |> assign(:sync_total, 0)
      |> assign(:sync_completed, 0)
      |> assign(:stale_integrations, [])
      |> assign(:oldest_sync_at, nil)
      |> assign(:_initialized, false)

    {:ok, socket}
  end

  # --- Update action handlers (delegated to UpdateHandlers) ---

  @impl Phoenix.LiveComponent
  def update(%{action: :revert_event} = assigns, socket),
    do: UpdateHandlers.handle_revert_event(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :refresh_events} = assigns, socket),
    do: UpdateHandlers.handle_refresh_events(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :reload_events} = assigns, socket),
    do: UpdateHandlers.handle_reload_events(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :ad_hoc_meeting_created} = assigns, socket),
    do: UpdateHandlers.handle_ad_hoc_meeting_created(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :ad_hoc_meeting_failed} = assigns, socket),
    do: UpdateHandlers.handle_ad_hoc_meeting_failed(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :event_created} = assigns, socket),
    do: UpdateHandlers.handle_event_created(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :event_create_failed} = assigns, socket),
    do: UpdateHandlers.handle_event_create_failed(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :event_moved} = assigns, socket),
    do: UpdateHandlers.handle_event_moved(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :event_deleted} = assigns, socket),
    do: UpdateHandlers.handle_event_deleted(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :event_delete_failed} = assigns, socket),
    do: UpdateHandlers.handle_event_delete_failed(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :events_updated} = assigns, socket),
    do: UpdateHandlers.handle_events_updated(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :video_link_updated} = assigns, socket),
    do: UpdateHandlers.handle_video_link_updated(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :integration_synced} = assigns, socket),
    do: UpdateHandlers.handle_integration_synced(assigns, socket)

  @impl Phoenix.LiveComponent
  def update(%{action: :refresh_guest_summaries}, socket),
    do: {:ok, assign_guest_rsvp_summaries(socket)}

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    was_initialized = socket.assigns[:_initialized]
    {:ok, socket} = UpdateHandlers.handle_initial(assigns, socket)
    just_initialized = socket.assigns[:_initialized] && !was_initialized

    socket =
      if just_initialized do
        assign_guest_rsvp_summaries(socket)
      else
        socket
      end

    {:ok, socket}
  end

  # Loads the `meeting_uid => RSVP summary` map for the calendar owner so
  # Tymeslot-created event blocks can show a guest indicator.
  defp assign_guest_rsvp_summaries(socket) do
    case socket.assigns[:current_user] do
      %{id: user_id} ->
        assign(socket, :guest_rsvp_summaries, Meetings.guest_rsvp_summaries_for_user(user_id))

      _other ->
        socket
    end
  end

  # --- Event handlers (delegated to focused modules) ---

  @impl Phoenix.LiveComponent
  def handle_event("show_event", params, socket),
    do: InlineEdit.handle_show_event(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("close_event_detail", params, socket),
    do: InlineEdit.handle_close_event_detail(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_event_title", params, socket),
    do: InlineEdit.handle_update_event_title(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_event_location", params, socket),
    do: InlineEdit.handle_update_event_location(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_event_description", params, socket),
    do: InlineEdit.handle_update_event_description(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_event_calendar", params, socket),
    do: InlineEdit.handle_update_event_calendar(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_edit_video", params, socket),
    do: InlineEdit.handle_update_edit_video(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_event_time", params, socket),
    do: InlineEdit.handle_update_event_time(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("toggle_event_all_day", params, socket),
    do: InlineEdit.handle_toggle_event_all_day(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_event_all_day_range", params, socket),
    do: InlineEdit.handle_update_event_all_day_range(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("add_event_reminder", params, socket),
    do: InlineEdit.handle_add_event_reminder(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("remove_event_reminder", params, socket),
    do: InlineEdit.handle_remove_event_reminder(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("prev_period", params, socket),
    do: Navigation.handle_prev_period(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("next_period", params, socket),
    do: Navigation.handle_next_period(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("today", params, socket),
    do: Navigation.handle_today(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("set_view", params, socket),
    do: Navigation.handle_set_view(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("navigate_to_day", params, socket),
    do: Navigation.handle_navigate_to_day(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("toggle_calendar_list", params, socket),
    do: Visibility.handle_toggle_calendar_list(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("toggle_view_menu", params, socket),
    do: Visibility.handle_toggle_view_menu(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("close_calendar_list", params, socket),
    do: Visibility.handle_close_calendar_list(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("close_view_menu", params, socket),
    do: Visibility.handle_close_view_menu(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("toggle_integration_visibility", params, socket),
    do: Visibility.handle_toggle_integration_visibility(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("refresh", params, socket),
    do: Visibility.handle_refresh(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("event_dropped", params, socket),
    do: DragDrop.handle_event_dropped(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("event_resized", params, socket),
    do: DragDrop.handle_event_resized(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("show_create_form", params, socket),
    do: EventCrud.handle_show_create_form(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("close_create_form", params, socket),
    do: EventCrud.handle_close_create_form(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_create_title", params, socket),
    do: EventCrud.handle_update_create_title(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_create_time", params, socket),
    do: EventCrud.handle_update_create_time(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("toggle_create_all_day", params, socket),
    do: EventCrud.handle_toggle_create_all_day(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_create_integration", params, socket),
    do: EventCrud.handle_update_create_integration(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("add_create_attendee", params, socket),
    do: EventCrud.handle_add_create_attendee(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("remove_create_attendee", params, socket),
    do: EventCrud.handle_remove_create_attendee(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_create_attendee_input", params, socket),
    do: EventCrud.handle_update_create_attendee_input(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_create_video", params, socket),
    do: EventCrud.handle_update_create_video(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("add_create_reminder", params, socket),
    do: EventCrud.handle_add_create_reminder(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("remove_create_reminder", params, socket),
    do: EventCrud.handle_remove_create_reminder(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("add_event_attendee", params, socket),
    do: AttendeeManagement.handle_add_event_attendee(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("request_remove_attendee", params, socket),
    do: AttendeeManagement.handle_request_remove_attendee(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("confirm_remove_attendee", params, socket),
    do: AttendeeManagement.handle_confirm_remove_attendee(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("cancel_remove_attendee", params, socket),
    do: AttendeeManagement.handle_cancel_remove_attendee(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("remove_pending_attendee", params, socket),
    do: AttendeeManagement.handle_remove_pending_attendee(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("discard_pending_attendees", params, socket),
    do: AttendeeManagement.handle_discard_pending_attendees(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("cancel_discard_attendees", params, socket),
    do: AttendeeManagement.handle_cancel_discard_attendees(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_attendee_input", params, socket),
    do: AttendeeManagement.handle_update_attendee_input(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("save_event", params, socket),
    do: EventCrud.handle_save_event(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("request_delete_event", params, socket),
    do: EventCrud.handle_request_delete_event(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("confirm_delete_event", params, socket),
    do: EventCrud.handle_confirm_delete_event(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("cancel_delete_event", params, socket),
    do: EventCrud.handle_cancel_delete_event(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("confirm_recurrence_scope", params, socket),
    do: EventCrud.handle_confirm_recurrence_scope(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("cancel_recurrence_prompt", params, socket),
    do: EventCrud.handle_cancel_recurrence_prompt(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("toggle_settings", params, socket),
    do: Preferences.handle_toggle_settings(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("close_settings", params, socket),
    do: Preferences.handle_close_settings(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("update_week_start", params, socket),
    do: Preferences.handle_update_preference(params, socket, :week_start_day)

  @impl Phoenix.LiveComponent
  def handle_event("update_time_format", params, socket),
    do: Preferences.handle_update_preference(params, socket, :time_format)

  @impl Phoenix.LiveComponent
  def handle_event("update_default_view", params, socket),
    do: Preferences.handle_update_default_view(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("toggle_week_numbers", params, socket),
    do: Preferences.handle_toggle_preference(params, socket, :show_week_numbers)

  @impl Phoenix.LiveComponent
  def handle_event("toggle_weekends", params, socket),
    do: Preferences.handle_toggle_preference(params, socket, :show_weekends)

  @impl Phoenix.LiveComponent
  def handle_event("set_mobile_view", params, socket),
    do: Navigation.handle_set_mobile_view(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("set_responsive_view", params, socket),
    do: Navigation.handle_set_responsive_view(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("navigate_swipe", params, socket),
    do: Navigation.handle_navigate_swipe(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("notify_prompt_confirm", params, socket),
    do: NotificationFlows.handle_notify_prompt_confirm(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("notify_prompt_cancel", params, socket),
    do: NotificationFlows.handle_notify_prompt_cancel(params, socket)

  @impl Phoenix.LiveComponent
  def handle_event("cancel_pending_notification", params, socket),
    do: NotificationFlows.handle_cancel_pending_notification(params, socket)

  # --- Render ---

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="calendar-grid" class="flex flex-col h-full relative" phx-hook="CalendarMobile" phx-target={@myself}>
      <.no_calendars_banner :if={@_initialized && @integrations == []} />
      <div :if={@_initialized && @integrations != []} class="flex-1 flex flex-col min-h-0">
        <Header.toolbar
          view={@view}
          date={@date}
          integrations={@integrations}
          integration_colors={@integration_colors}
          hidden_integration_ids={@hidden_integration_ids}
          show_calendar_list={@show_calendar_list}
          show_view_menu={@show_view_menu}
          syncing={@syncing}
          timezone_display={@timezone_display}
          timezone_country_code={@timezone_country_code}
          preferences={@preferences}
          myself={@myself}
        />
        <GridViews.week_day_view
          view={@view}
          visible_days={@visible_days}
          visible_events={@visible_events}
          events={@events}
          integrations={@integrations}
          integration_colors={@integration_colors}
          hidden_integration_ids={@hidden_integration_ids}
          current_time={@current_time}
          user_timezone={@user_timezone}
          preferences={@preferences}
          stale_integrations={@stale_integrations}
          oldest_sync_at={@oldest_sync_at}
          syncing={@syncing}
          sync_total={@sync_total}
          sync_completed={@sync_completed}
          date={@date}
          guest_rsvp_summaries={@guest_rsvp_summaries}
          myself={@myself}
        />
        <GridViews.month_view
          view={@view}
          visible_days={@visible_days}
          visible_events={@visible_events}
          integrations={@integrations}
          integration_colors={@integration_colors}
          hidden_integration_ids={@hidden_integration_ids}
          date={@date}
          user_timezone={@user_timezone}
          preferences={@preferences}
          guest_rsvp_summaries={@guest_rsvp_summaries}
          myself={@myself}
        />
        <CreateEventModal.create_event_modal
          :if={@creating_event}
          creating_event={@creating_event}
          integrations={@integrations}
          integration_colors={@integration_colors}
          saving={@saving_event}
          user_timezone={@user_timezone}
          myself={@myself}
          video_integrations={@video_integrations}
        />
        <RecurrencePromptModal.recurrence_prompt_modal
          :if={@recurrence_prompt}
          recurrence_prompt={@recurrence_prompt}
          myself={@myself}
        />
        <SettingsModal.settings_modal
          :if={@show_settings}
          preferences={@preferences}
          myself={@myself}
        />
        <EventDetailModal.event_detail_modal
          :if={@selected_event}
          selected_event={@selected_event}
          integrations={@integrations}
          integration_colors={@integration_colors}
          user_timezone={@user_timezone}
          time_format={Helpers.time_format(assigns)}
          myself={@myself}
          editable={MapSet.member?(@owned_integration_ids, @selected_event.calendar_integration_id)}
          attendee_input={@attendee_input}
          pending_attendees={@pending_attendees}
          video_integrations={@video_integrations}
          pending_notification={@pending_notification}
        />
        <NotifyPromptModal.notify_prompt_modal
          :if={@notify_prompt}
          notify_prompt={@notify_prompt}
          kind={@notify_prompt.kind}
          myself={@myself}
        />
        <ConfirmDeleteModal.confirm_delete_modal
          :if={@confirm_delete_event}
          event={@confirm_delete_event}
          deleting={@deleting_event}
          linked_to_booking={@confirm_delete_linked_to_booking}
          myself={@myself}
        />
        <ConfirmRemoveAttendeeModal.confirm_remove_attendee_modal
          :if={@confirm_remove_attendee}
          confirm_remove_attendee={@confirm_remove_attendee}
          myself={@myself}
        />
        <ConfirmDiscardAttendeesModal.confirm_discard_attendees_modal
          :if={@confirm_discard_attendees}
          count={
            if @selected_event,
              do: length(@pending_attendees),
              else: length((@creating_event || %{})[:attendees] || [])
          }
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  defp no_calendars_banner(assigns) do
    hours = Enum.to_list(6..20)
    days = ~w(Mon Tue Wed Thu Fri Sat Sun)
    assigns = assign(assigns, hours: hours, days: days)

    ~H"""
    <div class="relative flex-1 min-h-0 overflow-hidden">
      <%!-- Blurred calendar grid background --%>
      <div class="absolute inset-0 select-none" aria-hidden="true">
        <div class="h-full flex flex-col blur-[1px] opacity-60">
          <%!-- Day headers --%>
          <div class="grid grid-cols-8 border-b border-tymeslot-200">
            <div class="py-3 px-2"></div>
            <div :for={day <- @days} class="py-3 px-2 text-center border-l border-tymeslot-200">
              <span class="text-token-xs font-bold text-tymeslot-300">{day}</span>
            </div>
          </div>
          <%!-- Time rows --%>
          <div class="flex-1 overflow-hidden">
            <div :for={hour <- @hours} class="grid grid-cols-8 border-b border-tymeslot-200">
              <div class="py-4 px-2 text-right">
                <span class="text-token-xs text-tymeslot-300/50">{rem(hour, 12) |> then(&if(&1 == 0, do: 12, else: &1))} {if(hour < 12, do: "AM", else: "PM")}</span>
              </div>
              <div :for={_day <- @days} class="py-4 border-l border-tymeslot-200"></div>
            </div>
          </div>
        </div>
        <%!-- Gradient fade overlay --%>
        <div class="absolute inset-0 bg-linear-to-b from-white/40 via-transparent to-white/50"></div>
      </div>
      <%!-- Centred content --%>
      <div class="absolute inset-0 flex flex-col items-center justify-center px-6">
        <div class="w-20 h-20 bg-white/90 backdrop-blur rounded-token-2xl flex items-center justify-center mb-6 shadow-sm border-2 border-dashed border-tymeslot-100">
          <IconComponents.icon name={:calendar} class="w-10 h-10 text-tymeslot-300" />
        </div>
        <h2 class="text-token-xl font-bold text-tymeslot-800 mb-2">Nothing to see here</h2>
        <p class="text-token-base text-tymeslot-500 text-center max-w-md mb-8">
          Connect at least one calendar to see your events here.
        </p>
        <.link
          patch={~p"/dashboard/calendar-integration"}
          class="inline-flex items-center gap-2 px-6 py-3 bg-turquoise-600 hover:bg-turquoise-700 text-white font-bold rounded-token-xl transition-colors shadow-lg shadow-turquoise-500/20"
        >
          <.icon name="hero-plus" class="w-5 h-5" />
          Connect a calendar
        </.link>
      </div>
    </div>
    """
  end
end
