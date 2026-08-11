defmodule TymeslotWeb.DashboardLive do
  @moduledoc """
  The dashboard for authenticated users: one LiveView behind every
  `/dashboard/*` section.

  The sections are LiveComponents rather than separate LiveViews, so switching
  between them patches the page instead of remounting it, and the sidebar,
  integration status and profile are loaded once for all of them.
  `TymeslotWeb.Dashboard.ComponentDispatch` maps the current `live_action` to
  the component to render.

  Because every section shares this process, its mailbox is where components
  talk to each other: a child asks for a sibling to be refreshed, or for a flash
  to be shown, by messaging the parent. `handle_info/2` is therefore mostly a
  routing table, with the calendar and meeting-type-form traffic delegated to
  `TymeslotWeb.Dashboard.CalendarEventHandlers` and
  `TymeslotWeb.Dashboard.MeetingFormMessages`.

  ## Extensions

  External applications can add their own sections without Core knowing they
  exist: they register sidebar entries and components through application
  config, and route their paths to this LiveView with a custom `live_action`.
  `Tymeslot.Dashboard.ExtensionSchema` is the contract, and documents the
  configuration keys, the component requirements and the routing pattern.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Onboarding
  alias Tymeslot.Onboarding.DashboardTour
  alias TymeslotWeb.Components.DashboardLayout
  alias TymeslotWeb.Components.TourOverlay
  alias TymeslotWeb.Dashboard.AutomationSettingsComponent
  alias TymeslotWeb.Dashboard.CalendarEventHandlers
  alias TymeslotWeb.Dashboard.CalendarGridComponent
  alias TymeslotWeb.Dashboard.CalendarUpNextStrip
  alias TymeslotWeb.Dashboard.ComponentDispatch
  alias TymeslotWeb.Dashboard.MeetingFormMessages
  alias TymeslotWeb.Dashboard.OnboardingChecklist
  alias TymeslotWeb.Dashboard.PaymentsHandlers
  alias TymeslotWeb.Dashboard.ScheduleSettingsComponent
  alias TymeslotWeb.Dashboard.ServiceSettingsComponent
  alias TymeslotWeb.Dashboard.TourEventHandlers
  alias TymeslotWeb.Helpers.PageTitles

  require Logger

  # Cadence for the overview agenda's live refresh. Unlike the calendar
  # grid's query-free `:tick` (which only re-sends `current_time`), this
  # re-runs `Agenda.day_agenda/2` from the database every 60s to advance
  # the now-line, drop entries that have ended, and pick up bookings or
  # calendar events created since the last load.
  @agenda_tick_ms 60_000

  # The standalone calendar/video/payments pages now live as tabs inside the
  # unified integrations hub. Their routes stay defined (deep links, emails and
  # OAuth/Stripe returns still point at them) but each legacy live action bounces
  # to the matching hub tab.
  @legacy_integration_tabs %{
    calendar_integration: "calendars",
    video_integration: "video",
    payments: "payments"
  }

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    # Snapshot once, before the dashboard tour can mark itself seen mid-session,
    # so the overview greeting stays "Welcome" for the whole first visit and
    # only becomes "Welcome back" on a later one.
    first_visit? =
      case socket.assigns[:current_user] do
        %{} = user -> not Onboarding.dashboard_tour_seen?(user)
        _no_user -> false
      end

    # `:agenda` defaults nil so the calendar's Up-next strip can be guarded on
    # the dead render, before `load_dashboard_data/1` has run.
    {:ok, assign(socket, first_dashboard_visit: first_visit?, agenda: nil)}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, _url, socket) do
    case Map.fetch(@legacy_integration_tabs, socket.assigns.live_action) do
      {:ok, tab} ->
        socket =
          if socket.assigns.live_action == :payments && !socket.assigns.payments_allowed do
            put_flash(
              socket,
              :error,
              dgettext("dashboard_home", "Meeting payments require an upgraded plan.")
            )
          else
            socket
          end

        {:noreply, push_navigate(socket, to: hub_tab_path(tab, params))}

      :error ->
        {:noreply, handle_dashboard_params(params, socket)}
    end
  end

  # Builds the hub URL for a legacy redirect, carrying the Stripe onboarding
  # return markers (`?return=1`/`?refresh=1`) through so the hub still triggers
  # the capability resync once the user lands on the payments tab.
  defp hub_tab_path(tab, params) do
    passthrough =
      for key <- [:return, :refresh],
          Map.has_key?(params, Atom.to_string(key)),
          do: {key, params[Atom.to_string(key)]}

    query = [{:tab, tab} | passthrough]
    ~p"/dashboard/integrations?#{query}"
  end

  defp handle_dashboard_params(params, socket) do
    action = socket.assigns.live_action

    socket =
      if connected?(socket) && action == :calendar &&
           !socket.assigns[:calendar_pubsub_subscribed] do
        user_id = socket.assigns.current_user.id

        Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user_id}")
        Phoenix.PubSub.subscribe(Tymeslot.PubSub, "dashboard_guests:#{user_id}")

        assign(socket, :calendar_pubsub_subscribed, true)
      else
        socket
      end

    socket =
      socket
      |> assign(:page_title, PageTitles.dashboard_title(action))
      |> assign(:params, params)
      |> TourEventHandlers.assign_tour_state(action)

    socket =
      if action == :integrations,
        do: PaymentsHandlers.maybe_enqueue_resync(params, socket),
        else: socket

    socket = if connected?(socket), do: load_dashboard_data(socket), else: socket
    reschedule_agenda_tick(socket, action)
  end

  # Keeps a single agenda-refresh timer alive only while a section that shows
  # the agenda (overview, calendar's Up-next strip) is open. Cancels any prior
  # timer first so repeated visits never stack ticks.
  defp reschedule_agenda_tick(socket, action) when action in [:overview, :calendar] do
    if ref = socket.assigns[:agenda_tick_ref], do: Process.cancel_timer(ref)

    if connected?(socket) do
      assign(socket, :agenda_tick_ref, Process.send_after(self(), :agenda_tick, @agenda_tick_ms))
    else
      assign(socket, :agenda_tick_ref, nil)
    end
  end

  defp reschedule_agenda_tick(socket, _action) do
    if ref = socket.assigns[:agenda_tick_ref], do: Process.cancel_timer(ref)
    assign(socket, :agenda_tick_ref, nil)
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :component_module,
        ComponentDispatch.component_for_action(
          assigns.live_action,
          assigns[:dashboard_action_components]
        )
      )
      |> assign(:component_props, ComponentDispatch.props_for_action(assigns))
      |> assign(
        :should_render_feature,
        ComponentDispatch.should_render_feature?(assigns.live_action, assigns)
      )

    ~H"""
    <DashboardLayout.dashboard_layout
      current_user={@current_user}
      profile={@profile}
      current_action={@live_action}
      integration_status={@integration_status}
      automations_allowed={@automations_allowed}
      analytics_allowed={@analytics_allowed}
      full_width={@live_action == :calendar}
      sidebar_extensions={@sidebar_extensions}
      unseen_announcements={@unseen_announcements}
    >
      <.live_component
        :if={@tour_active}
        module={TourOverlay}
        id="dashboard-tour-overlay"
        step={DashboardTour.step_at(@tour_step_index)}
        step_index={@tour_step_index}
        total_steps={@tour_total_steps}
      />
      <.flash_group flash={@flash} id="dashboard-flash-group" />

      <%!-- Content --%>
      <div class={if @live_action == :calendar, do: "flex-1 flex flex-col min-h-0", else: ""}>
        <%= if @live_action == :calendar do %>
          <div
            :if={OnboardingChecklist.visible?(@current_user, @integration_status)}
            class="shrink-0 px-3 pt-2 md:px-4"
          >
            <OnboardingChecklist.onboarding_checklist
              variant={:compact}
              integration_status={@integration_status}
              current_user={@current_user}
              profile={@profile}
            />
          </div>
          <CalendarUpNextStrip.up_next_strip
            :if={@agenda && @agenda.next}
            entry={@agenda.next}
            timezone={@agenda.timezone}
            time_format={@time_format}
          />
        <% end %>
        <div class={
          if @live_action == :calendar, do: "flex-1 min-h-0 flex flex-col", else: "contents"
        }>
          <%= if @should_render_feature do %>
            <.live_component
              module={@component_module}
              id={ComponentDispatch.component_id(@live_action)}
              current_user={@current_user}
              first_dashboard_visit={@first_dashboard_visit}
              profile={Map.get(@component_props, :profile, @profile)}
              shared_data={Map.get(@component_props, :shared_data, %{})}
              integration_status={@integration_status}
              time_format={@time_format}
              saving={@saving}
              client_ip={@client_ip}
              user_agent={@user_agent}
              live_action={@live_action}
              params={@params}
              custom_questions_allowed={@custom_questions_allowed}
              payments_allowed={@payments_allowed}
            />
          <% else %>
            <ComponentDispatch.feature_placeholder
              section={@live_action}
              current_user={@current_user}
              feature_placeholder_components={@feature_placeholder_components}
            />
          <% end %>
        </div>
      </div>
    </DashboardLayout.dashboard_layout>
    """
  end

  # Handle events from child components
  @impl Phoenix.LiveView
  @spec handle_info({:profile_updated, map()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:profile_updated, profile}, socket) do
    {:noreply,
     socket
     |> assign(profile: profile)
     |> handle_saving_animation()
     |> refresh_dashboard_data()}
  end

  # The clock is resolved once at mount, so changing it in settings has to be
  # announced or the rest of the dashboard keeps rendering the old one until the
  # next full page load.
  @spec handle_info({:time_format_updated, String.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:time_format_updated, time_format}, socket) do
    {:noreply, assign(socket, time_format: time_format)}
  end

  @spec handle_info(
          {:integration_added | :integration_removed | :integration_updated, any()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({event, _type}, socket)
      when event in [:integration_added, :integration_removed, :integration_updated] do
    {:noreply,
     socket
     |> handle_saving_animation()
     |> refresh_dashboard_data()}
  end

  @spec handle_info({:meeting_type_changed}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:meeting_type_changed}, socket) do
    if socket.assigns.live_action == :meeting_settings do
      send_update(ServiceSettingsComponent, id: ComponentDispatch.component_id(:meeting_settings))
    end

    {:noreply,
     socket
     |> handle_saving_animation()
     |> refresh_dashboard_data()
     |> load_dashboard_data()}
  end

  @spec handle_info({:flash, {atom(), String.t()}}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:flash, {type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end

  @impl Phoenix.LiveView
  def handle_info({:hide_saving, gen}, socket) do
    if gen == socket.assigns[:saving_gen] do
      {:noreply, assign(socket, saving: false, saving_timer_ref: nil)}
    else
      # Stale timer message from a cancelled generation — ignore
      {:noreply, socket}
    end
  end

  # Form-related messages forwarded from MeetingTypeForm and its child components
  # are delegated to TymeslotWeb.Dashboard.MeetingFormMessages.

  @impl Phoenix.LiveView
  def handle_info({:clear_reminder_confirmation, form_id}, socket),
    do: MeetingFormMessages.handle_clear_reminder_confirmation(form_id, socket)

  def handle_info({:refresh_calendar_list, form_id, integration_id}, socket),
    do: MeetingFormMessages.handle_refresh_calendar_list(form_id, integration_id, socket)

  def handle_info({:calendar_list_refreshed, form_id, _integration_id, calendars}, socket),
    do: MeetingFormMessages.handle_calendar_list_refreshed(form_id, calendars, socket)

  def handle_info({:retry_autosave, form_id}, socket),
    do: MeetingFormMessages.handle_retry_autosave(form_id, socket)

  # Generic external redirect message from components.
  # Only HTTPS URLs are allowed to prevent open-redirect attacks from
  # malicious or buggy extension components.
  @spec handle_info({:external_redirect, String.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:external_redirect, url}, socket) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        {:noreply, redirect(socket, external: url)}

      _other ->
        Logger.warning("Rejected external redirect to non-HTTPS URL",
          url: url,
          user_id: socket.assigns[:current_user] && socket.assigns.current_user.id
        )

        {:noreply, put_flash(socket, :error, dgettext("dashboard_home", "Invalid redirect URL"))}
    end
  end

  @spec handle_info({:reload_schedule}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:reload_schedule}, socket) do
    # Refresh the availability component after mutations from child components
    send_update(ScheduleSettingsComponent,
      id: ComponentDispatch.component_id(:availability),
      profile: socket.assigns.profile
    )

    {:noreply, socket}
  end

  @spec handle_info({:telegram_linked, integer(), String.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:telegram_linked, integration_id, _chat_id}, socket) do
    send_update(AutomationSettingsComponent,
      id: ComponentDispatch.component_id(:automation),
      telegram_linked_integration_id: integration_id
    )

    {:noreply, socket}
  end

  @spec handle_info({:telegram_link_expired, integer()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:telegram_link_expired, integration_id}, socket) do
    send_update(AutomationSettingsComponent,
      id: ComponentDispatch.component_id(:automation),
      telegram_link_expired_id: integration_id
    )

    {:noreply, socket}
  end

  # Calendar-specific handle_info clauses — delegated to CalendarEventHandlers.

  def handle_info({:guest_rsvp_updated, _meeting_id}, socket) do
    send_update(
      CalendarGridComponent,
      id: ComponentDispatch.component_id(:calendar),
      action: :refresh_guest_summaries
    )

    {:noreply, socket}
  end

  def handle_info(:tick, socket),
    do: CalendarEventHandlers.handle_tick(socket)

  def handle_info(:agenda_tick, socket) do
    {:noreply, socket |> reschedule_agenda_tick(socket.assigns.live_action) |> refresh_agenda()}
  end

  def handle_info({:calendar_events_updated, _user_id, _changed_uids}, socket),
    do: CalendarEventHandlers.handle_calendar_events_updated(socket)

  def handle_info({:calendar_sync_complete, _user_id, _integration_id}, socket),
    do: CalendarEventHandlers.handle_calendar_sync_complete(socket)

  def handle_info(:calendar_sync_flash, socket),
    do: CalendarEventHandlers.handle_calendar_sync_flash(socket)

  def handle_info(:reset_calendar_sync, socket),
    do: CalendarEventHandlers.handle_reset_calendar_sync(socket)

  def handle_info({:event_update_result, result}, socket),
    do: CalendarEventHandlers.handle_event_update_result(result, socket)

  def handle_info({:event_move_result, result}, socket),
    do: CalendarEventHandlers.handle_event_move_result(result, socket)

  def handle_info({:video_sync_result, event_id, result}, socket),
    do: CalendarEventHandlers.handle_video_sync_result(event_id, result, socket)

  def handle_info({:execute_create_event, payload}, socket),
    do: CalendarEventHandlers.handle_execute_create_event(payload, socket)

  def handle_info({:create_event_result, result}, socket),
    do: CalendarEventHandlers.handle_create_event_result(result, socket)

  def handle_info({:execute_create_ad_hoc_meeting, params}, socket),
    do: CalendarEventHandlers.handle_execute_create_ad_hoc_meeting(params, socket)

  def handle_info({:create_ad_hoc_meeting_result, result}, socket),
    do: CalendarEventHandlers.handle_create_ad_hoc_meeting_result(result, socket)

  def handle_info({:execute_delete_event, payload}, socket),
    do: CalendarEventHandlers.handle_execute_delete_event(payload, socket)

  def handle_info({:delete_event_result, result}, socket),
    do: CalendarEventHandlers.handle_delete_event_result(result, socket)

  @spec handle_info(any(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(_msg, socket) do
    # Silently ignore unhandled messages
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("tour:" <> action, params, socket),
    do: TourEventHandlers.handle_event(action, params, socket)

  def handle_event("onboarding:toggle", %{"id" => key}, socket) do
    user = socket.assigns.current_user

    with true <- OnboardingChecklist.toggleable_item?(key),
         {:ok, user} <- Onboarding.toggle_dashboard_setup_item(user, key) do
      {:noreply, assign(socket, :current_user, user)}
    else
      _invalid_or_error -> {:noreply, socket}
    end
  end

  def handle_event("onboarding:dismiss", _params, socket) do
    case Onboarding.dismiss_dashboard_setup(socket.assigns.current_user) do
      {:ok, user} -> {:noreply, assign(socket, :current_user, user)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  # Private functions

  @spec handle_saving_animation(Phoenix.LiveView.Socket.t(), non_neg_integer()) ::
          Phoenix.LiveView.Socket.t()
  defp handle_saving_animation(socket, duration \\ 1000) do
    if ref = socket.assigns[:saving_timer_ref] do
      Process.cancel_timer(ref)
    end

    gen = (socket.assigns[:saving_gen] || 0) + 1
    ref = Process.send_after(self(), {:hide_saving, gen}, duration)
    assign(socket, saving: true, saving_timer_ref: ref, saving_gen: gen)
  end

  # Refreshes integration status only — used after integration events.
  # Action-specific data (e.g. upcoming meetings) is loaded exclusively by
  # handle_params/3 and does not need to change when an integration is added
  # or removed.
  @spec refresh_dashboard_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp refresh_dashboard_data(socket) do
    if user = socket.assigns[:current_user] do
      DashboardContext.invalidate_integration_status(user.id)
      integration_status = DashboardContext.get_integration_status(user.id)
      assign(socket, :integration_status, integration_status)
    else
      socket
    end
  end

  @spec load_dashboard_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_dashboard_data(socket) do
    user = socket.assigns[:current_user]
    action = socket.assigns[:live_action]
    timezone = socket.assigns[:profile] && socket.assigns.profile.timezone

    if user do
      dashboard_data = DashboardContext.get_dashboard_data_for_action(user, timezone, action)
      assign(socket, dashboard_data)
    else
      socket
    end
  end

  # Rebuilds only the agenda on a tick; a stale timer that fires after the
  # user has navigated elsewhere is a no-op.
  defp refresh_agenda(%{assigns: %{live_action: action}} = socket)
       when action in [:overview, :calendar],
       do: load_dashboard_data(socket)

  defp refresh_agenda(socket), do: socket
end
