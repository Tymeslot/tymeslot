defmodule TymeslotWeb.Themes.Core.Dispatcher do
  @moduledoc """
  Theme dispatcher LiveView that delegates to theme-specific implementations.

  This LiveView acts as a dispatcher, routing to the appropriate theme-specific
  LiveView based on the user's theme preference. This ensures complete theme
  independence while maintaining a consistent interface.
  """
  use TymeslotWeb, :live_view

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Meetings
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Themes.{Registry, Theme}
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.Helpers
  alias TymeslotWeb.Themes.Core.{Context, ErrorBoundary, EventBus}
  alias TymeslotWeb.Themes.Shared.Customization.Helpers, as: ThemeCustomizationHelpers
  alias TymeslotWeb.Themes.Shared.{EventHandlers, LocaleHandler, PathHandlers}

  require Logger

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    # Initialize locale dropdown state
    socket = assign(socket, :language_dropdown_open, false)

    # For all routes with username (including meeting management), resolve the username first
    if params["username"] do
      socket = Helpers.handle_username_resolution(socket, params["username"])

      case socket.assigns do
        %{organizer_profile: %{} = profile} ->
          mount_with_profile(profile, params, session, socket)

        %{error: error} ->
          {:ok, assign(socket, :error, error)}

        _no_profile ->
          mount_without_profile(params, session, socket)
      end
    else
      mount_without_profile(params, session, socket)
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, url, socket) do
    # Sync locale from params if present
    socket =
      if locale = params["locale"] do
        LocaleHandler.handle_locale_change(socket, locale)
      else
        socket
      end

    # Check if this is a meeting management action
    action = socket.assigns[:live_action]

    if action in [:reschedule, :cancel, :cancel_confirmed] do
      # For meeting management, we don't need handle_params
      {:noreply, socket}
    else
      delegate_handle_params(params, url, socket)
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_language_dropdown", _params, socket) do
    EventHandlers.handle_toggle_language_dropdown(socket)
  end

  def handle_event("close_language_dropdown", _params, socket) do
    EventHandlers.handle_close_language_dropdown(socket)
  end

  def handle_event("change_locale", %{"locale" => locale}, socket) do
    EventHandlers.handle_change_locale(socket, locale, PathHandlers)
  end

  def handle_event("cancel_meeting" = event, params, socket),
    do: handle_meeting_event(event, params, socket)

  def handle_event("keep_meeting" = event, params, socket),
    do: handle_meeting_event(event, params, socket)

  def handle_event(event, params, socket) do
    # For scheduling actions, delegate to the theme
    theme_id = socket.assigns[:theme_id] || Registry.default_theme_id()
    delegate_to_theme(theme_id, :handle_event, [event, params, socket])
  end

  @impl Phoenix.LiveView
  def handle_info({:theme_event, _event} = msg, socket) do
    # Handle theme events
    socket = EventBus.handle_event(elem(msg, 1), socket)
    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    theme_id = socket.assigns[:theme_id] || Registry.default_theme_id()
    delegate_to_theme(theme_id, :handle_info, [msg, socket])
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # Ensure Gettext locale is set correctly for this render cycle
    if locale = assigns[:locale] do
      Gettext.put_locale(TymeslotWeb.Gettext, locale)
    end

    cond do
      msg = assigns[:error] ->
        render_error(assigns, msg)

      error_context = assigns[:theme_error] ->
        # Use theme_error_message if available, fallback to format_error
        msg = assigns[:theme_error_message] || ErrorBoundary.format_error(error_context)
        render_error(assigns, msg)

      msg = assigns[:scheduling_error_message] ->
        render_error(assigns, msg)

      true ->
        action = assigns[:live_action]

        if action in [:reschedule, :cancel, :cancel_confirmed] do
          render_meeting_management_component(assigns, action)
        else
          render_scheduling_component(assigns)
        end
    end
  end

  # Private functions

  defp render_meeting_management_component(assigns, action) do
    theme_id = assigns[:theme_id] || Registry.default_theme_id()

    case Theme.get_theme_module(theme_id) do
      nil ->
        render_error(assigns, "Theme not found for meeting management")

      module ->
        try do
          module.render_meeting_action(assigns, action)
        rescue
          e in UndefinedFunctionError ->
            Logger.error(
              "render_meeting_action not implemented in theme module #{inspect(module)}: #{inspect(e)}"
            )

            render_error(assigns, "Meeting action rendering not implemented for this theme")

          e ->
            Logger.error(
              "Error rendering meeting action #{action} for theme #{theme_id}: #{inspect(e)}"
            )

            render_error(assigns, "Meeting action rendering failed")
        end
    end
  end

  defp render_scheduling_component(assigns) do
    theme_id = assigns[:theme_id] || Registry.default_theme_id()

    case Theme.get_live_view_module(theme_id) do
      nil ->
        render_error(assigns, "Theme not found")

      module ->
        try do
          module.render(assigns)
        rescue
          e in UndefinedFunctionError ->
            Logger.error(
              "Render function not implemented in theme module #{inspect(module)}: #{inspect(e)}"
            )

            render_error(assigns, "Theme render function not found")

          e ->
            Logger.error("Error rendering theme", theme_id: theme_id, error: inspect(e))
            render_error(assigns, "Theme rendering failed")
        end
    end
  end

  defp delegate_to_theme(theme_id, function, args) do
    case Theme.get_live_view_module(theme_id) do
      nil ->
        Logger.error("Theme module not found", theme_id: theme_id)
        handle_theme_error(function, args)

      module ->
        # Add theme_id to socket assigns if not present
        args = ensure_theme_id_in_socket(args, theme_id)

        # Use error boundary for safe execution
        ErrorBoundary.wrap_callback(theme_id, module, function, args)
    end
  end

  # Helper to flatten handle_params logic
  defp delegate_handle_params(params, url, socket) do
    theme_id =
      case socket.assigns do
        %{theme_id: current_theme_id} ->
          override = params["theme"]
          if override && override != current_theme_id, do: override, else: current_theme_id

        _no_theme ->
          params["theme"] || params["theme_id"] || Registry.default_theme_id()
      end

    socket = assign(socket, :theme_id, theme_id)
    delegate_to_theme(theme_id, :handle_params, [params, url, socket])
  end

  defp ensure_theme_id_in_socket(args, theme_id) do
    case args do
      [params, session, socket] when is_map(session) or is_nil(session) ->
        [params, session, assign(socket, :theme_id, theme_id)]

      [params, url, socket] when is_binary(url) ->
        [params, url, assign(socket, :theme_id, theme_id)]

      [event, params, socket] ->
        [event, params, assign(socket, :theme_id, theme_id)]

      [msg, socket] ->
        [msg, assign(socket, :theme_id, theme_id)]

      _unknown_format ->
        args
    end
  end

  defp handle_theme_error(:mount, [_params, _session, socket]) do
    {:ok, assign(socket, :error, "Theme loading failed")}
  end

  defp handle_theme_error(:handle_params, [_params, _url, socket]) do
    {:noreply, assign(socket, :error, "Theme navigation failed")}
  end

  defp handle_theme_error(:handle_event, [_event, _params, socket]) do
    {:noreply, assign(socket, :error, "Theme event handling failed")}
  end

  defp handle_theme_error(:handle_info, [_msg, socket]) do
    {:noreply, assign(socket, :error, "Theme message handling failed")}
  end

  defp handle_theme_error(_unknown_function, _unknown_args), do: {:error, "Unknown theme error"}

  defp render_error(assigns, message) do
    assigns = assign(assigns, :error_message, message)

    ~H"""
    <div class="min-h-screen bg-gray-100 flex items-center justify-center">
      <div class="bg-white p-8 rounded-lg shadow-md max-w-md w-full">
        <div class="text-center">
          <div class="text-red-500 text-6xl mb-4">⚠️</div>
          <h1 class="text-xl font-bold text-gray-900 mb-2">Theme Error</h1>
          <p class="text-gray-600 mb-4">{@error_message}</p>
          <button
            id="theme-error-retry-button"
            phx-hook="PageReload"
            class="bg-blue-500 hover:bg-blue-600 text-white px-4 py-2 rounded"
          >
            Retry
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp mount_with_profile(profile, params, session, socket) do
    action = socket.assigns[:live_action]

    log_mount_debug_info(action, profile, socket)

    if action in [:reschedule, :cancel, :cancel_confirmed] && params["meeting_uid"] do
      mount_meeting_management(profile, params, socket, action)
    else
      mount_scheduling_flow(profile, params, session, socket)
    end
  end

  defp mount_without_profile(params, session, socket) do
    # If username was provided but no profile found, redirect to homepage
    if params["username"] && is_nil(socket.assigns[:organizer_profile]) do
      {:ok,
       socket
       |> LiveView.put_flash(:error, "Page not found. Redirected to homepage.")
       |> LiveView.redirect(to: "/")}
    else
      # Create theme context without profile
      case Context.from_params(params) do
        %Context{} = context ->
          # Subscribe to theme events
          EventBus.subscribe_to_theme(context.theme_id)

          # Assign the context to socket
          socket = Context.assign_to_socket(socket, context)

          # Emit theme mounted event
          EventBus.emit_theme_mounted(context.theme_id, %{
            preview_mode: context.preview_mode
          })

          delegate_to_theme(context.theme_id, :mount, [params, session, socket])

        nil ->
          {:ok, assign(socket, :error, "Failed to load theme context")}
      end
    end
  end

  # Mount helpers

  defp log_mount_debug_info(_unused_action, _unused_profile, _unused_socket) do
    # Debug logging removed for production
  end

  defp mount_meeting_management(profile, params, socket, action) do
    theme_id = profile.booking_theme || socket.assigns[:theme_id] || "1"
    meeting_uid = params["meeting_uid"]

    case validate_and_load_meeting(meeting_uid, action) do
      {:ok, meeting} ->
        socket =
          setup_meeting_management_socket(
            socket,
            profile,
            meeting,
            meeting_uid,
            theme_id,
            action,
            params
          )

        {:ok, socket}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, reason)
         |> push_navigate(to: "/")}
    end
  end

  defp mount_scheduling_flow(profile, params, session, socket) do
    # Enforce readiness on first render for public links
    case LinkAccessPolicy.check_public_readiness(profile) do
      {:ok, :ready} ->
        case prepare_theme_context(profile, params, socket) do
          {:ok, context, socket} ->
            EventBus.emit_theme_mounted(context.theme_id, %{
              user_id: profile.user_id,
              preview_mode: context.preview_mode
            })

            delegate_to_theme(context.theme_id, :mount, [params, session, socket])

          {:error, error_socket} ->
            {:ok, error_socket}
        end

      {:error, reason} ->
        # Build theme context and render a theme-specific error page without redirecting
        case prepare_theme_context(profile, params, socket) do
          {:ok, _context, socket} ->
            {:ok,
             socket
             |> LiveView.clear_flash()
             |> LiveView.put_flash(:error, LinkAccessPolicy.reason_to_message(reason))
             |> Component.assign(:scheduling_error_reason, reason)
             |> Component.assign(
               :scheduling_error_message,
               LinkAccessPolicy.reason_to_message(reason)
             )}

          {:error, error_socket} ->
            {:ok, error_socket}
        end
    end
  end

  defp setup_meeting_management_socket(
         socket,
         profile,
         meeting,
         meeting_uid,
         theme_id,
         action,
         params
       ) do
    socket =
      socket
      |> assign(:theme_id, theme_id)
      |> assign(:organizer_profile, profile)
      |> assign(:meeting, meeting)
      |> assign(:meeting_uid, meeting_uid)
      |> assign(:loading, false)
      |> assign(:has_theme, true)

    socket = assign_action_specific_data(socket, action, meeting, params)
    assign_theme_customization_data(socket, profile, theme_id)
  end

  defp assign_action_specific_data(socket, :reschedule, meeting, params) do
    duration_str = DateTimeUtils.format_duration_for_url(meeting.duration)

    socket
    |> assign_user_timezone(params)
    |> assign(:duration, duration_str)
  end

  defp assign_action_specific_data(socket, _other_action, _unused_meeting, _unused_params),
    do: socket

  defp assign_theme_customization_data(socket, profile, theme_id) do
    ThemeCustomizationHelpers.assign_theme_customization(socket, profile, theme_id)
  end

  defp prepare_theme_context(profile, params, socket) do
    case Context.from_params(params, profile) do
      %Context{} = context ->
        EventBus.subscribe_to_theme(context.theme_id)

        socket =
          socket
          |> Context.assign_to_socket(context)
          |> ThemeCustomizationHelpers.assign_theme_customization(profile, context.theme_id)

        {:ok, context, socket}

      nil ->
        {:error, assign(socket, :error, "Failed to load theme context")}
    end
  end

  # Meeting management helpers

  defp validate_and_load_meeting(meeting_uid, action) do
    case MeetingQueries.get_meeting_by_uid(meeting_uid) do
      {:ok, meeting} ->
        case validate_meeting_action(meeting, action) do
          :ok -> {:ok, meeting}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, "Meeting not found"}
    end
  end

  defp validate_meeting_action(meeting, :cancel) do
    Policy.can_cancel_meeting?(meeting)
  end

  defp validate_meeting_action(meeting, :reschedule) do
    Policy.can_reschedule_meeting?(meeting)
  end

  defp validate_meeting_action(_unused_meeting, :cancel_confirmed) do
    :ok
  end

  defp assign_user_timezone(socket, params) do
    timezone =
      params["timezone"] || socket.assigns[:user_timezone] ||
        Profiles.get_default_timezone()

    # Normalize and validate
    normalized_timezone = Timezones.normalize(timezone)

    validated_timezone =
      if Timezones.valid?(normalized_timezone) do
        normalized_timezone
      else
        Profiles.get_default_timezone()
      end

    assign(socket, :user_timezone, validated_timezone)
  end

  # Handle events for meeting management
  defp handle_meeting_event("cancel_meeting", _unused_params, socket) do
    if socket.assigns[:live_action] == :cancel do
      meeting = socket.assigns[:meeting]
      client_ip = ClientIP.get(socket)

      case RateLimiter.check_meeting_cancel_rate_limit(client_ip) do
        :ok ->
          case Meetings.cancel_meeting(meeting) do
            {:ok, _result} ->
              cancel_confirmed_url = build_cancel_confirmed_url(socket, meeting)

              # Use redirect instead of push_navigate to force full page reload
              {:noreply, redirect(socket, to: cancel_confirmed_url)}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to cancel meeting: #{reason}")}
          end

        {:error, :rate_limited, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  defp handle_meeting_event("keep_meeting", _unused_params, socket) do
    if socket.assigns[:live_action] == :cancel do
      client_ip = ClientIP.get(socket)

      case RateLimiter.check_meeting_keep_rate_limit(client_ip) do
        :ok ->
          # Set a flag to show the "kept" state instead of the cancel form
          {:noreply, assign(socket, :meeting_kept, true)}

        {:error, :rate_limited, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  defp build_cancel_confirmed_url(socket, meeting) do
    case socket.assigns[:organizer_profile] do
      %{username: username} when is_binary(username) and byte_size(username) > 0 ->
        "/#{username}/meeting/#{meeting.uid}/cancel-confirmed"

      _no_username ->
        "/meeting/#{meeting.uid}/cancel-confirmed"
    end
  end
end
