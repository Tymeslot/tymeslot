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
            icon: :puzzle,
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
  - `:icon` (atom) - Icon name from `TymeslotWeb.Components.Icons.IconComponents`
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

  alias Phoenix.Naming
  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Profiles
  alias TymeslotWeb.Components.DashboardLayout
  alias TymeslotWeb.Helpers.PageTitles

  alias TymeslotWeb.Dashboard.{
    AutomationSettingsComponent,
    BookingsManagementComponent,
    CalendarEventHandlers,
    CalendarGridComponent,
    CalendarSettingsComponent,
    DashboardOverviewComponent,
    ProfileSettingsComponent,
    ScheduleSettingsComponent,
    ServiceSettingsComponent,
    ThemeSettingsComponent,
    VideoSettingsComponent
  }

  alias TymeslotWeb.Live.Dashboard.EmbedSettingsComponent

  alias Ecto.UUID
  alias Tymeslot.CustomFields.FieldDefinition
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm

  require Logger

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, _url, socket) do
    action = socket.assigns.live_action

    socket =
      if connected?(socket) && action == :calendar &&
           !socket.assigns[:calendar_pubsub_subscribed] do
        Phoenix.PubSub.subscribe(
          Tymeslot.PubSub,
          "calendar_events:#{socket.assigns.current_user.id}"
        )

        assign(socket, :calendar_pubsub_subscribed, true)
      else
        socket
      end

    socket =
      socket
      |> assign(:page_title, PageTitles.dashboard_title(action))
      |> assign(:params, params)

    socket = if connected?(socket), do: load_dashboard_data(socket), else: socket

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :component_module,
        component_for_action(assigns.live_action, assigns[:dashboard_action_components])
      )
      |> assign(:component_props, props_for_action(assigns))
      |> assign(:should_render_feature, should_render_feature?(assigns.live_action, assigns))

    ~H"""
    <DashboardLayout.dashboard_layout
      current_user={@current_user}
      profile={@profile}
      current_action={@live_action}
      integration_status={@integration_status}
      automations_allowed={@automations_allowed}
      full_width={@live_action == :calendar}
      sidebar_extensions={@sidebar_extensions}
      unseen_announcements={@unseen_announcements}
    >
      <.flash_group flash={@flash} id="dashboard-flash-group" />

      <%!-- Content --%>
      <div class={if @live_action == :calendar, do: "flex-1 flex flex-col min-h-0", else: ""}>
        <%= if @should_render_feature do %>
          <.live_component
            module={@component_module}
            id={component_id(@live_action)}
            current_user={@current_user}
            profile={Map.get(@component_props, :profile, @profile)}
            shared_data={Map.get(@component_props, :shared_data, %{})}
            integration_status={@integration_status}
            saving={@saving}
            client_ip={@client_ip}
            user_agent={@user_agent}
            live_action={@live_action}
            params={@params}
          />
        <% else %>
          <.render_feature_placeholder
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
      send_update(ServiceSettingsComponent, id: component_id(:meeting_settings))
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

  @impl Phoenix.LiveView
  def handle_info({:clear_reminder_confirmation, form_id}, socket) do
    send_update(TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm,
      id: form_id,
      reminder_confirmation: nil
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:refresh_calendar_list, form_id, integration_id}, socket) do
    user_id = socket.assigns.current_user.id
    Calendar.refresh_calendar_list_async(integration_id, user_id, form_id)
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:calendar_list_refreshed, form_id, _integration_id, calendars}, socket) do
    send_update(TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm,
      id: form_id,
      refreshing_calendars: false,
      available_calendars: Selection.selected_calendars(calendars)
    )

    {:noreply, socket}
  end

  # -------------------------------------------------------------------------
  # Custom questions — forwarded from MeetingTypeForm child components
  # -------------------------------------------------------------------------
  # Child LiveComponents (CustomQuestionsSection, QuestionEditorComponent) use
  # `send(self(), {:custom_questions, action, …, form_id})` to bubble mutations
  # upward to DashboardLive, which owns the LiveView process. Each handler calls
  # `send_update/3` to push new assigns back to the correct MeetingTypeForm
  # instance.
  #
  # Children compute derived state locally (e.g. the new ordered list after a
  # delete) and send the completed result — not the raw intent. This avoids
  # the need for DashboardLive to read component assigns.

  @impl Phoenix.LiveView
  def handle_info({:custom_questions, :open_add, form_id, current_fields}, socket) do
    empty = %FieldDefinition{
      id: UUID.generate(),
      type: "short_text",
      position: length(current_fields)
    }

    send_update(MeetingTypeForm, id: form_id, editing_question: empty)
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:custom_questions, :open_edit, question, form_id}, socket) do
    send_update(MeetingTypeForm, id: form_id, editing_question: question)
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:custom_questions, :cancel, form_id}, socket) do
    send_update(MeetingTypeForm, id: form_id, editing_question: nil)
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:custom_questions, :fields_updated, updated_fields, form_id}, socket) do
    send_update(MeetingTypeForm,
      id: form_id,
      custom_fields: updated_fields,
      editing_question: nil
    )

    {:noreply, socket}
  end

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

        {:noreply, put_flash(socket, :error, "Invalid redirect URL")}
    end
  end

  @spec handle_info({:announcement_cta_navigate, String.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:announcement_cta_navigate, path}, socket) when is_binary(path) do
    {:noreply, push_navigate(socket, to: path)}
  end

  @spec handle_info({:reload_schedule}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:reload_schedule}, socket) do
    # Refresh the availability component after mutations from child components
    send_update(ScheduleSettingsComponent,
      id: component_id(:availability),
      profile: socket.assigns.profile
    )

    {:noreply, socket}
  end

  @spec handle_info({:telegram_linked, integer(), String.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:telegram_linked, integration_id, _chat_id}, socket) do
    send_update(AutomationSettingsComponent,
      id: component_id(:automation),
      telegram_linked_integration_id: integration_id
    )

    {:noreply, socket}
  end

  @spec handle_info({:telegram_link_expired, integer()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:telegram_link_expired, integration_id}, socket) do
    send_update(AutomationSettingsComponent,
      id: component_id(:automation),
      telegram_link_expired_id: integration_id
    )

    {:noreply, socket}
  end

  # Calendar-specific handle_info clauses — delegated to CalendarEventHandlers.

  def handle_info(:tick, socket),
    do: CalendarEventHandlers.handle_tick(socket)

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

  # Private functions

  # Returns a stable string id for a component rendered for the given action.
  # All send_update/2 calls must use this function to ensure the id matches
  # the id assigned in render/1.
  @spec component_id(atom()) :: String.t()
  defp component_id(action), do: to_string(action)

  @spec should_render_feature?(atom(), map()) :: boolean()
  defp should_render_feature?(action, assigns) do
    gates = assigns[:dashboard_feature_gates] || %{}

    case Map.get(gates, action) do
      nil -> true
      assign_key -> Map.get(assigns, assign_key, true)
    end
  end

  attr :section, :atom, required: true
  attr :current_user, :any, required: true
  attr :feature_placeholder_components, :map, required: true

  @spec render_feature_placeholder(map()) :: Phoenix.LiveView.Rendered.t()
  defp render_feature_placeholder(assigns) do
    assigns =
      assigns
      |> assign(:placeholder_component, assigns.feature_placeholder_components[assigns.section])
      |> assign(:feature_name, Naming.humanize(assigns.section))

    ~H"""
    <%= if @placeholder_component do %>
      <.live_component
        module={@placeholder_component}
        id={"#{@section}_placeholder"}
        current_user={@current_user}
        feature={@section}
      />
    <% else %>
      <%!-- Core fallback: just show a simple message --%>
      <div class="p-8 text-center text-tymeslot-500">
        <p>This feature ({@feature_name}) is not available on your current plan.</p>
      </div>
    <% end %>
    """
  end

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

  @spec component_for_action(atom(), map() | nil) :: module()
  defp component_for_action(:overview, _components), do: DashboardOverviewComponent
  defp component_for_action(:settings, _components), do: ProfileSettingsComponent
  defp component_for_action(:availability, _components), do: ScheduleSettingsComponent
  defp component_for_action(:meeting_settings, _components), do: ServiceSettingsComponent
  defp component_for_action(:calendar, _components), do: CalendarGridComponent
  defp component_for_action(:calendar_integration, _components), do: CalendarSettingsComponent
  defp component_for_action(:video_integration, _components), do: VideoSettingsComponent
  defp component_for_action(:automation, _components), do: AutomationSettingsComponent
  defp component_for_action(:theme, _components), do: ThemeSettingsComponent
  defp component_for_action(:theme_customization, _components), do: ThemeSettingsComponent
  defp component_for_action(:meetings, _components), do: BookingsManagementComponent
  defp component_for_action(:embed, _components), do: EmbedSettingsComponent

  defp component_for_action(action, components) do
    Map.get(components || %{}, action, DashboardOverviewComponent)
  end

  # Returns a map of assign overrides for the given action.
  # Only actions that need to transform assigns before passing them to the component
  # are listed here; all other actions receive the socket assigns directly.
  @spec props_for_action(map()) :: map()
  defp props_for_action(%{live_action: :overview} = assigns) do
    %{shared_data: %{upcoming_meetings: assigns[:upcoming_meetings] || []}}
  end

  defp props_for_action(%{live_action: action} = assigns)
       when action in [:settings, :availability] do
    %{profile: Profiles.prefill_timezone(assigns.profile, assigns[:detected_timezone])}
  end

  defp props_for_action(_assigns), do: %{}

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

    if user do
      dashboard_data = DashboardContext.get_dashboard_data_for_action(user.email, action)
      assign(socket, dashboard_data)
    else
      socket
    end
  end
end
