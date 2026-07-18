defmodule TymeslotWeb.DashboardLive do
  @moduledoc """
  Main dashboard LiveView for authenticated users.

  This module serves as the central hub for all dashboard functionality,
  including user settings, integrations, availability management, and more.

  ## Dashboard Extension System

  The dashboard is designed to be extensible, allowing external applications
  (such as the SaaS layer) to inject additional navigation items and components
  without modifying Core code. This maintains strict architectural separation
  while enabling powerful customization.

  ### How Extensions Work

  Extensions are registered via application configuration and consumed at runtime:

  1. **Navigation Extensions** - Add new sidebar menu items
  2. **Component Extensions** - Provide LiveComponents for custom actions

  ### Registering Extensions

  External applications should register extensions during startup using
  `Application.put_env/3`. This is typically done in the application's
  `start/2` callback:

      # In external_app/lib/external_app/application.ex
      defp configure_dashboard_extensions do
        # Register sidebar navigation items
        Application.put_env(:tymeslot, :dashboard_sidebar_extensions, [
          %{
            id: :my_feature,
            label: "My Feature",
            icon: "hero-puzzle-piece",
            path: "/dashboard/my-feature",
            action: :my_feature
          }
        ])

        # Register corresponding components
        Application.put_env(:tymeslot, :dashboard_action_components, %{
          my_feature: ExternalApp.Dashboard.MyFeatureComponent
        })
      end

  ### Extension Schema

  Each sidebar extension must be a map with the following keys:

  - `:id` (atom) - Unique identifier for this extension
  - `:label` (string) - Display text shown in the sidebar
  - `:icon` (string) - A `hero-…` icon name (see `TymeslotWeb.Components.CoreComponents.Icons`)
  - `:path` (string) - Route path (must start with "/")
  - `:action` (atom) - LiveView action for routing and highlighting

  See `Tymeslot.Dashboard.ExtensionSchema` for validation utilities.

  ### Extension Component Requirements

  Components registered via `:dashboard_action_components` must:

  1. Be a LiveComponent (`use Phoenix.LiveComponent`)
  2. Accept standard dashboard assigns in `update/2`:
     - `current_user` - The authenticated user
     - `profile` - The user's profile
     - `integration_status` - Integration connection status
     - `client_ip` - The client's IP address
     - `user_agent` - The client's User Agent string
     - `shared_data` - Shared dashboard statistics/data

  Example component:

      defmodule ExternalApp.Dashboard.MyFeatureComponent do
        use Phoenix.LiveComponent

        @impl Phoenix.LiveView
        def update(assigns, socket) do
          {:ok, assign(socket, assigns)}
        end

        @impl Phoenix.LiveView
        def render(assigns) do
          ~H\"\"\"
          <div>
            <h1>My Feature</h1>
            <p>User: {@current_user.email}</p>
          </div>
          \"\"\"
        end
      end

  ### Routing for Extensions

  External applications must also register routes. The recommended pattern is:

      # In external_app_web/router.ex
      scope "/dashboard" do
        pipe_through [:browser, :require_authenticated_user]

        live_session :external_dashboard,
          on_mount: [
            {TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated},
            TymeslotWeb.Hooks.ClientInfoHook,
            TymeslotWeb.Hooks.DashboardInitHook
          ] do
          # Reuse Core's DashboardLive, but with your custom action
          live "/my-feature", TymeslotWeb.DashboardLive, :my_feature
        end
      end

      # Forward remaining routes to Core
      forward "/", TymeslotWeb.Router

  ### Extension Validation

  To ensure extensions are valid at startup:

      alias Tymeslot.Dashboard.ExtensionSchema

      extensions = Application.get_env(:tymeslot, :dashboard_sidebar_extensions, [])

      case ExtensionSchema.validate_all(extensions) do
        :ok -> :ok
        {:error, errors} ->
          Logger.error("Invalid dashboard extensions", errors: inspect(errors))
          raise "Dashboard extension validation failed"
      end

  ### Architecture Notes

  This extension system follows the "Dependency Inversion Principle":

  - **Core defines the interface** (config keys, expected structure)
  - **External apps implement the interface** (provide extensions)
  - **Core never knows about external apps** (no imports, no coupling)

  The Core application can run completely standalone without any extensions.
  Extensions are purely additive and optional.

  For more details on the architecture, see `CLAUDE.md` in the project root.
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
  alias TymeslotWeb.Dashboard.ComponentDispatch
  alias TymeslotWeb.Dashboard.MeetingFormMessages
  alias TymeslotWeb.Dashboard.OnboardingChecklist
  alias TymeslotWeb.Dashboard.PaymentsHandlers
  alias TymeslotWeb.Dashboard.Polls.PollsComponent
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

    {:ok, assign(socket, :first_dashboard_visit, first_visit?)}
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

  # Keeps a single agenda-refresh timer alive only while the overview is open.
  # Cancels any prior timer first so repeated visits never stack ticks.
  defp reschedule_agenda_tick(socket, :overview) do
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
        <%= if @should_render_feature do %>
          <.live_component
            module={@component_module}
            id={ComponentDispatch.component_id(@live_action)}
            current_user={@current_user}
            first_dashboard_visit={@first_dashboard_visit}
            profile={Map.get(@component_props, :profile, @profile)}
            shared_data={Map.get(@component_props, :shared_data, %{})}
            integration_status={@integration_status}
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

  # A poll's votes or lifecycle changed. Route it to the Polls component, which
  # subscribed on the host's behalf and refreshes the on-screen results.
  @spec handle_info({:poll_updated, Ecto.UUID.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:poll_updated, poll_id}, socket) do
    send_update(PollsComponent, id: ComponentDispatch.component_id(:polls), poll_updated: poll_id)
    {:noreply, socket}
  end

  # The Polls component's advisory slot-health check runs in a supervised task
  # and reports back here; route it to the component.
  @spec handle_info({:poll_slot_health, Ecto.UUID.t(), map()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:poll_slot_health, poll_id, health}, socket) do
    send_update(PollsComponent,
      id: ComponentDispatch.component_id(:polls),
      poll_slot_health: {poll_id, health}
    )

    {:noreply, socket}
  end

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

  # Rebuilds only the overview agenda on a tick; a stale timer that fires after
  # the user has navigated elsewhere is a no-op.
  defp refresh_agenda(%{assigns: %{live_action: :overview}} = socket),
    do: load_dashboard_data(socket)

  defp refresh_agenda(socket), do: socket
end
