defmodule TymeslotWeb.DashboardLive do
  use TymeslotWeb, :live_view

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Timezone
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Security.{RateLimiter, SettingsInputProcessor}
  alias TymeslotWeb.Components.DashboardLayout
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Helpers.PageTitles
  alias TymeslotWeb.Helpers.{ThemeUploadHelper, UploadConstraints}
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.InitHelpers

  # Alias dashboard components to satisfy aliasing rules and improve maintainability
  alias TymeslotWeb.Dashboard.{
    BookingsManagementComponent,
    CalendarSettingsComponent,
    DashboardOverviewComponent,
    PaymentLiveComponent,
    ProfileSettingsComponent,
    ScheduleSettingsComponent,
    ServiceSettingsComponent,
    ThemeSettingsComponent,
    VideoSettingsComponent
  }

  # Dashboard components are loaded dynamically based on the current action

  require Logger

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    InitHelpers.with_user_context(socket, fn socket ->
      connect_params = get_connect_params(socket) || %{}
      detected_timezone = connect_params["timezone"]
      user = socket.assigns.current_user

      socket =
        socket
        |> assign(shared_data: %{})
        |> assign(detected_timezone: detected_timezone)

      socket =
        if user do
          {:ok, socket} = DashboardHelpers.mount_dashboard_common(socket)
          socket
        else
          assign_dev_profile(socket)
        end

      {:ok, load_shared_data(socket)}
    end)
  end

  defp assign_dev_profile(socket) do
    assign(socket, :profile, %{
      id: 1,
      user_id: 1,
      username: "dev-user",
      full_name: "Development User",
      timezone: "Europe/Kyiv",
      buffer_minutes: 15,
      advance_booking_days: 90,
      min_advance_hours: 3,
      avatar: nil,
      booking_theme: "1"
    })
  end

  @impl true
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(_params, _url, socket) do
    action = socket.assigns.live_action

    socket =
      socket
      |> assign(:page_title, PageTitles.dashboard_title(action))
      |> load_section_specific_data(action)
      |> maybe_configure_uploads(action)

    {:noreply, socket}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <DashboardLayout.dashboard_layout
      current_user={@current_user}
      profile={@profile}
      current_action={@live_action}
      integration_status={get_integration_status(assigns)}
    >
      <.flash_group flash={@flash} id="dashboard-flash-group" />

    <!-- Content -->
      <div class="dashboard-content">
        {render_section(assigns)}
      </div>
    </DashboardLayout.dashboard_layout>
    """
  end

  # Handle copy scheduling link event
  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("copy_scheduling_link", _params, socket) do
    profile = socket.assigns.profile
    path = LinkAccessPolicy.scheduling_path(profile)
    url = "#{Endpoint.url()}#{path}"

    {:noreply,
     socket
     |> push_event("copy-to-clipboard", %{text: url})
     |> put_flash(:info, "Scheduling link copied to clipboard!")}
  end

  # Handle avatar upload events when on settings page
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_avatar", _params, socket) do
    # Validation is handled automatically by Phoenix LiveView
    {:noreply, socket}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("upload_avatar", _params, socket) do
    if socket.assigns.live_action == :settings do
      # Get the metadata for security validation
      metadata = %{
        ip: ClientIP.get(socket),
        user_agent: ClientIP.get_user_agent(socket),
        user_id: socket.assigns.current_user.id
      }

      # Send message to consume the upload
      send(self(), {:consume_avatar_upload, socket.assigns.profile, metadata})
    end

    {:noreply, socket}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_image", _params, socket) do
    {:noreply, socket}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("save_background_image", _params, socket) do
    {:noreply, maybe_handle_theme_upload(socket, :image)}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_video", _params, socket) do
    # Validation is handled automatically by Phoenix LiveView
    {:noreply, socket}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("save_background_video", _params, socket) do
    {:noreply, maybe_handle_theme_upload(socket, :video)}
  end

  # Handle events from child components
  @impl true
  @spec handle_info({:theme_customization_opened, any()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:theme_customization_opened, theme_id}, socket) do
    {:noreply, assign(socket, :current_customization_theme_id, theme_id)}
  end

  @spec handle_info(:theme_customization_closed, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:theme_customization_closed, socket) do
    {:noreply, assign(socket, :current_customization_theme_id, nil)}
  end

  @spec handle_info({:profile_updated, map()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:profile_updated, profile}, socket) do
    # Invalidate cache when profile is updated
    DashboardContext.invalidate_integration_status(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(profile: profile)
     |> load_shared_data()}
  end

  @spec handle_info({:integration_added, any()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:integration_added, _type}, socket) do
    # Invalidate cache when integrations change
    DashboardContext.invalidate_integration_status(socket.assigns.current_user.id)

    {:noreply, load_shared_data(socket)}
  end

  @spec handle_info({:integration_removed, any()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:integration_removed, _type}, socket) do
    # Invalidate cache when integrations change
    DashboardContext.invalidate_integration_status(socket.assigns.current_user.id)

    {:noreply, load_shared_data(socket)}
  end

  @spec handle_info({:integration_updated, any()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:integration_updated, _type}, socket) do
    # Invalidate cache when integrations are enabled/disabled
    DashboardContext.invalidate_integration_status(socket.assigns.current_user.id)

    {:noreply, load_shared_data(socket)}
  end

  @spec handle_info({:meeting_type_changed}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:meeting_type_changed}, socket) do
    # Invalidate cache when meeting types change
    DashboardContext.invalidate_integration_status(socket.assigns.current_user.id)

    # Reload data based on current section
    socket =
      if socket.assigns.live_action == :meeting_settings do
        # Reload meeting types for the meeting settings page
        load_section_specific_data(socket, :meeting_settings)
      else
        # For other pages, just reload shared data
        load_shared_data(socket)
      end

    {:noreply, socket}
  end

  @spec handle_info({:flash, {atom(), String.t()}}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:flash, {type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end

  @spec handle_info({:user_updated, map()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:user_updated, user}, socket) do
    {:noreply, assign(socket, :current_user, user)}
  end

  @spec handle_info(:reset_avatar_upload, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:reset_avatar_upload, socket) do
    # Reset the upload configuration after avatar deletion
    if socket.assigns.live_action == :settings do
      # Simply disallow and re-allow to get a fresh configuration
      # This is mainly called after deletion, not after consumption
      socket =
        socket
        |> disallow_upload(:avatar)
        |> allow_upload(:avatar,
          accept: ~w(.jpg .jpeg .png .gif .webp),
          max_entries: 1,
          max_file_size: 10_000_000
        )

      # Force update the settings component to get the new upload configuration
      send_update(ProfileSettingsComponent,
        id: "settings",
        parent_uploads: socket.assigns.uploads
      )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @spec handle_info({:consume_avatar_upload, map(), map()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:consume_avatar_upload, profile, metadata}, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :avatar, &process_avatar_entry(profile, &1, &2, metadata))

    # Send the result back to the component
    send_update(TymeslotWeb.Dashboard.ProfileSettingsComponent,
      id: "settings",
      avatar_upload_result: uploaded_files
    )

    {:noreply, socket}
  end

  @spec handle_info({:consume_avatar_upload, map()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:consume_avatar_upload, profile}, socket) do
    uploaded_files =
      consume_uploaded_entries(
        socket,
        :avatar,
        &process_avatar_entry(profile, &1, &2, socket.assigns[:security_metadata])
      )

    # Send the result back to the component
    send_update(TymeslotWeb.Dashboard.ProfileSettingsComponent,
      id: "settings",
      avatar_upload_result: uploaded_files
    )

    {:noreply, socket}
  end

  @spec handle_info({:consume_background_video_upload, map()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:consume_background_video_upload, profile}, socket) do
    case ThemeUploadHelper.process_background_video_upload(socket, profile) do
      {:ok, message} ->
        send(self(), {:flash, {:info, message}})
        {:noreply, socket}

      {:error, message} ->
        send(self(), {:flash, {:error, message}})
        {:noreply, socket}
    end
  end

  # Handle calendar OAuth redirects directly in the parent LiveView

  # Neutral redirect message from the Video settings component
  @spec handle_info({:video_redirect, String.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:video_redirect, url}, socket) when is_binary(url) do
    {:noreply, redirect(socket, external: url)}
  end

  # Generic external redirect message from components
  @spec handle_info({:external_redirect, String.t()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:external_redirect, url}, socket) when is_binary(url) do
    {:noreply, redirect(socket, external: url)}
  end

  @spec handle_info({:reload_schedule}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:reload_schedule}, socket) do
    # Refresh the availability component after mutations from child components
    send_update(ScheduleSettingsComponent,
      id: "availability",
      profile: socket.assigns.profile
    )

    {:noreply, socket}
  end

  @spec handle_info(any(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(_msg, socket) do
    # Silently ignore unhandled messages
    {:noreply, socket}
  end

  defp process_avatar_entry(profile, %{path: path}, entry, metadata) do
    uploaded_entry = %{"path" => path, "client_name" => entry.client_name}

    case SettingsInputProcessor.validate_avatar_upload(uploaded_entry, metadata: metadata) do
      {:ok, validated_entry} ->
        atom_entry = %{path: validated_entry["path"], client_name: validated_entry["client_name"]}

        case Profiles.update_avatar(profile, atom_entry) do
          {:ok, updated_profile} -> {:ok, updated_profile}
          {:error, reason} -> {:postpone, reason}
        end

      {:error, validation_error} ->
        {:postpone, validation_error}
    end
  end

  # Private functions

  @spec render_section(map()) :: Phoenix.LiveView.Rendered.t()
  defp render_section(assigns) do
    assigns =
      assigns
      |> assign(:component_module, component_for_action(assigns.live_action))
      |> assign(:component_props, props_for_action(assigns))

    ~H"""
    <.live_component
      module={@component_module}
      id={to_string(@live_action)}
      current_user={@component_props.current_user}
      profile={@component_props[:profile]}
      shared_data={@component_props[:shared_data]}
      integration_status={@component_props[:integration_status]}
      meeting_types={@component_props[:meeting_types]}
      video_integrations={@component_props[:video_integrations]}
      client_ip={@component_props[:client_ip]}
      user_agent={@component_props[:user_agent]}
      parent_uploads={
        if (@live_action == :settings || @live_action == :theme) && Map.has_key?(assigns, :uploads),
          do: @uploads,
          else: nil
      }
    />
    """
  end

  @spec component_for_action(atom()) :: module()
  defp component_for_action(:overview), do: DashboardOverviewComponent
  defp component_for_action(:settings), do: ProfileSettingsComponent

  defp component_for_action(:availability), do: ScheduleSettingsComponent

  defp component_for_action(:meeting_settings), do: ServiceSettingsComponent

  defp component_for_action(:calendar), do: CalendarSettingsComponent
  defp component_for_action(:video), do: VideoSettingsComponent
  defp component_for_action(:theme), do: ThemeSettingsComponent
  defp component_for_action(:meetings), do: BookingsManagementComponent
  defp component_for_action(:payment), do: PaymentLiveComponent
  defp component_for_action(_), do: DashboardOverviewComponent

  @spec props_for_action(map()) :: map()
  defp props_for_action(%{live_action: action} = assigns) do
    base_props = %{
      current_user: assigns.current_user,
      profile: assigns.profile,
      integration_status: get_integration_status(assigns),
      client_ip: assigns.client_ip,
      user_agent: assigns.user_agent
    }

    case action do
      :overview ->
        Map.put(base_props, :shared_data, assigns.shared_data)

      :settings ->
        # Prefill timezone for settings using the same logic as onboarding, without persisting
        Map.put(base_props, :profile, apply_timezone_prefill(assigns))

      :availability ->
        # Prefill timezone for availability page using detected browser timezone
        Map.put(base_props, :profile, apply_timezone_prefill(assigns))

      _ ->
        base_props
    end
  end

  @spec apply_timezone_prefill(map()) :: map() | nil
  defp apply_timezone_prefill(assigns) do
    if assigns.profile do
      prefilled_tz =
        Timezone.prefill_timezone(assigns.profile.timezone, assigns[:detected_timezone])

      Map.put(assigns.profile, :timezone, prefilled_tz)
    else
      assigns.profile
    end
  end

  @spec load_shared_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_shared_data(socket) do
    user = socket.assigns.current_user
    user_id = if user, do: user.id, else: nil
    user_email = if user, do: user.email, else: nil

    if socket.assigns[:live_action] == :overview do
      # Load full shared data for overview page
      shared_data = DashboardContext.get_dashboard_data(user_id, user_email)
      assign(socket, :shared_data, shared_data)
    else
      # For other pages, only load integration status for sidebar notifications
      integration_status = DashboardContext.get_integration_status(user_id)
      assign(socket, :shared_data, %{integration_status: integration_status})
    end
  end

  @spec load_section_specific_data(Phoenix.LiveView.Socket.t(), atom()) ::
          Phoenix.LiveView.Socket.t()
  defp load_section_specific_data(socket, action) do
    case action do
      :overview ->
        # Load overview data if not already loaded
        if socket.assigns[:shared_data] do
          socket
        else
          load_shared_data(socket)
        end

      _ ->
        socket
    end
  end

  @spec get_integration_status(map()) :: map()
  defp get_integration_status(assigns) do
    # Get integration status from shared_data if available
    if assigns[:shared_data] && assigns.shared_data[:integration_status] do
      assigns.shared_data.integration_status
    else
      # This shouldn't happen since load_shared_data now always sets integration_status
      %{
        has_calendar: false,
        has_video: false,
        has_meeting_types: false,
        calendar_count: 0,
        video_count: 0,
        meeting_types_count: 0
      }
    end
  end

  defp maybe_configure_uploads(socket, :settings) do
    # Configure uploads for settings page
    if socket.assigns[:uploads] && socket.assigns.uploads[:avatar] do
      # Upload already configured, don't reconfigure
      socket
    else
      allow_upload(socket, :avatar,
        accept: ~w(.jpg .jpeg .png .gif .webp),
        max_entries: 1,
        max_file_size: 10_000_000
      )
    end
  end

  defp maybe_configure_uploads(socket, :theme) do
    # Configure uploads for theme customization page
    if socket.assigns[:uploads] && socket.assigns.uploads[:background_image] do
      # Upload already configured, don't reconfigure
      socket
    else
      img_exts = UploadConstraints.allowed_extensions(:image)
      vid_exts = UploadConstraints.allowed_extensions(:video)

      socket
      |> allow_upload(:background_image,
        accept: img_exts,
        max_entries: 1,
        max_file_size: UploadConstraints.max_file_size(:image)
      )
      |> allow_upload(:background_video,
        accept: vid_exts,
        max_entries: 1,
        max_file_size: UploadConstraints.max_file_size(:video)
      )
    end
  end

  defp maybe_configure_uploads(socket, _action) do
    # No uploads needed for other pages
    socket
  end

  defp maybe_handle_theme_upload(socket, _type) when socket.assigns.live_action != :theme,
    do: socket

  defp maybe_handle_theme_upload(socket, type) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_rate_limit("theme_upload:#{user_id}", 5, 600_000) do
      :ok ->
        send(self(), build_theme_upload_message(type, socket.assigns.profile))
        socket

      {:error, :rate_limited} ->
        send(
          self(),
          {:flash, {:error, "Too many upload attempts. Please wait a few minutes and try again."}}
        )

        socket
    end
  end

  defp build_theme_upload_message(:image, profile),
    do: {:consume_background_image_upload, profile}

  defp build_theme_upload_message(:video, profile),
    do: {:consume_background_video_upload, profile}
end
