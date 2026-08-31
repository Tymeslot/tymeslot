defmodule TymeslotWeb.Themes.Core.Dispatcher do
  @moduledoc """
  Theme dispatcher LiveView that delegates to theme-specific implementations.

  This LiveView acts as a dispatcher, routing to the appropriate theme-specific
  LiveView based on the user's theme preference. This ensures complete theme
  independence while maintaining a consistent interface.
  """
  use TymeslotWeb, :live_view

  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers

  alias TymeslotWeb.Themes.Core.{
    ErrorBoundary,
    MeetingManagement,
    MountHelpers,
    PollVoting,
    Registry,
    ThemeInfo
  }

  alias TymeslotWeb.Themes.Shared.{EventHandlers, LocaleHandler, PathHandlers}

  require Logger

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    # Initialize locale dropdown state
    socket = assign(socket, :language_dropdown_open, false)

    # For all routes with username (including meeting management), resolve the username first
    if params["username"] do
      socket = OrganizerHelpers.handle_username_resolution(socket, params["username"])

      case socket.assigns do
        %{organizer_profile: %{} = profile} ->
          MountHelpers.mount_with_profile(profile, params, session, socket, &delegate_to_theme/3)

        %{error: error} ->
          {:ok, assign(socket, :error, error)}

        _no_profile ->
          MountHelpers.mount_without_profile(params, session, socket, &delegate_to_theme/3)
      end
    else
      MountHelpers.mount_without_profile(params, session, socket, &delegate_to_theme/3)
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, url, socket) do
    # Track the request path so the root layout can build the canonical/og:url
    # on the static (crawler) render, where no conn is available.
    socket = assign(socket, :request_path, URI.parse(url).path || "/")

    # Sync locale from params if present
    socket =
      if locale = params["locale"] do
        LocaleHandler.handle_locale_change(socket, locale)
      else
        socket
      end

    # Check if this is a meeting management action
    action = socket.assigns[:live_action]

    if action in [:reschedule, :cancel, :cancel_confirmed, :poll_voting] do
      # Meeting management and poll voting have no scheduling params to delegate.
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
    do: MeetingManagement.handle_meeting_event(event, params, socket)

  def handle_event("keep_meeting" = event, params, socket),
    do: MeetingManagement.handle_meeting_event(event, params, socket)

  def handle_event("register_participant" = event, params, socket),
    do: PollVoting.handle_poll_event(event, params, socket)

  def handle_event("cast_votes" = event, params, socket),
    do: PollVoting.handle_poll_event(event, params, socket)

  def handle_event(event, params, socket) do
    # For scheduling actions, delegate to the theme
    theme_id = socket.assigns[:theme_id] || Registry.default_theme_id()
    delegate_to_theme(theme_id, :handle_event, [event, params, socket])
  end

  @impl Phoenix.LiveView
  def handle_info({:poll_updated, _poll_id} = msg, socket),
    do: PollVoting.handle_poll_info(msg, socket)

  def handle_info(msg, socket) do
    theme_id = socket.assigns[:theme_id] || Registry.default_theme_id()
    delegate_to_theme(theme_id, :handle_info, [msg, socket])
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # Ensure Gettext locale is set correctly for this render cycle
    if locale = assigns[:locale] do
      Gettext.put_locale(locale)
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

        cond do
          action in [:reschedule, :cancel, :cancel_confirmed] ->
            render_meeting_management_component(assigns, action)

          action == :poll_voting ->
            render_poll_voting_component(assigns)

          true ->
            render_scheduling_component(assigns)
        end
    end
  end

  # Private functions

  defp render_poll_voting_component(assigns) do
    theme_id = assigns[:theme_id] || Registry.default_theme_id()

    case ThemeInfo.get_theme_module(theme_id) do
      nil ->
        render_error(assigns, "Theme not found for poll voting")

      module ->
        try do
          module.render_poll_action(assigns)
        rescue
          e in UndefinedFunctionError ->
            Logger.error("render_poll_action not implemented in theme module",
              module: inspect(module),
              error: inspect(e)
            )

            render_error(assigns, "Poll voting rendering not implemented for this theme")

          e ->
            Logger.error("Error rendering poll voting", theme_id: theme_id, error: inspect(e))
            render_error(assigns, "Poll voting rendering failed")
        end
    end
  end

  defp render_meeting_management_component(assigns, action) do
    theme_id = assigns[:theme_id] || Registry.default_theme_id()

    case ThemeInfo.get_theme_module(theme_id) do
      nil ->
        render_error(assigns, "Theme not found for meeting management")

      module ->
        try do
          module.render_meeting_action(assigns, action)
        rescue
          e in UndefinedFunctionError ->
            Logger.error("render_meeting_action not implemented in theme module",
              module: inspect(module),
              error: inspect(e)
            )

            render_error(assigns, "Meeting action rendering not implemented for this theme")

          e ->
            Logger.error("Error rendering meeting action",
              action: action,
              theme_id: theme_id,
              error: inspect(e)
            )

            render_error(assigns, "Meeting action rendering failed")
        end
    end
  end

  defp render_scheduling_component(assigns) do
    theme_id = assigns[:theme_id] || Registry.default_theme_id()

    case ThemeInfo.get_live_view_module(theme_id) do
      nil ->
        render_error(assigns, "Theme not found")

      module ->
        try do
          module.render(assigns)
        rescue
          e in UndefinedFunctionError ->
            Logger.error("Render function not implemented in theme module",
              module: inspect(module),
              error: inspect(e)
            )

            render_error(assigns, "Theme render function not found")

          e ->
            Logger.error("Error rendering theme", theme_id: theme_id, error: inspect(e))
            render_error(assigns, "Theme rendering failed")
        end
    end
  end

  defp delegate_to_theme(theme_id, function, args) do
    case ThemeInfo.get_live_view_module(theme_id) do
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
        Logger.warning("ensure_theme_id_in_socket: unknown args format",
          args_length: length(args)
        )

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
    <div class="min-h-screen bg-tymeslot-100 flex items-center justify-center">
      <div class="bg-white p-8 rounded-lg shadow-md max-w-md w-full">
        <div class="text-center">
          <div class="text-red-500 text-6xl mb-4">⚠️</div>
          <h1 class="text-xl font-bold text-tymeslot-900 mb-2">Theme Error</h1>
          <p class="text-tymeslot-600 mb-4">{@error_message}</p>
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
end
