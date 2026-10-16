defmodule TymeslotWeb.Themes.Core.Dispatcher do
  @moduledoc """
  Theme dispatcher LiveView that delegates to theme-specific implementations.

  This LiveView acts as a dispatcher, routing to the appropriate theme-specific
  LiveView based on the user's theme preference. This ensures complete theme
  independence while maintaining a consistent interface.
  """
  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.ErrorTracking
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

  # A `start_async/3` result: a task reports to the LiveView that started it,
  # which for a booking page is always this one, so the result goes to the
  # theme as a message does (the flow's week of slots, `WeekSlots`).
  @impl Phoenix.LiveView
  def handle_async(name, result, socket) do
    theme_id = socket.assigns[:theme_id] || Registry.default_theme_id()
    delegate_to_theme(theme_id, :handle_async, [name, result, socket])
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

      # An organiser who has not connected a calendar yet is a configuration
      # state, not a crash, so it goes to the theme, which shows it in the
      # organiser's own branding via `Shared.Components.ErrorComponent`. The
      # notice replaces the whole booker, poll route included, so it is decided
      # here rather than per action. `render_error/2` stays reserved for a theme
      # that could not be loaded or that raised inside a callback.
      assigns[:scheduling_error_message] ->
        render_scheduling_component(assigns)

      true ->
        case assigns[:live_action] do
          action when action in [:reschedule, :cancel, :cancel_confirmed] ->
            render_theme(
              assigns,
              ErrorBoundary.load_failed_message(),
              & &1.render_meeting_action(assigns, action)
            )

          :poll_voting ->
            render_theme(
              assigns,
              ErrorBoundary.load_failed_message(),
              & &1.render_poll_action(assigns)
            )

          _scheduling ->
            render_scheduling_component(assigns)
        end
    end
  end

  # Private functions

  defp render_scheduling_component(assigns) do
    render_theme(
      assigns,
      ErrorBoundary.load_failed_message(),
      & &1.live_view_module().render(assigns)
    )
  end

  # Renders through the current theme's module. An id that resolves to no
  # theme falls back to the error card, and so does an exception raised while
  # the theme builds its render. An exception inside the template's dynamic
  # parts is raised later, when the render is turned into HTML, and crashes
  # the LiveView instead. Every callback exists (the compiler checks the
  # behaviour), so any exception here is a real error in the theme, logged as
  # such.
  defp render_theme(assigns, failure_message, render) do
    theme_id = assigns[:theme_id] || Registry.default_theme_id()

    case ThemeInfo.get_theme_module(theme_id) do
      nil ->
        Logger.error("Theme module not found", theme_id: theme_id)
        render_error(assigns, ErrorBoundary.load_failed_message())

      module ->
        try do
          render.(module)
        rescue
          e ->
            ErrorTracking.report_error(e, __STACKTRACE__, %{theme_id: theme_id})
            render_error(assigns, failure_message)
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
          Registry.requested_theme_id(params) || current_theme_id

        _no_theme ->
          Registry.requested_theme_id(params) || Registry.default_theme_id()
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

  # The theme could not be resolved at all, so the error boundary never ran;
  # show the visitor the same message it would have.
  defp handle_theme_error(:mount = function, [_params, _session, socket]),
    do: {:ok, assign_theme_error(socket, function)}

  defp handle_theme_error(function, [_first, _second, socket])
       when function in [:handle_params, :handle_event, :handle_async],
       do: {:noreply, assign_theme_error(socket, function)}

  defp handle_theme_error(:handle_info = function, [_msg, socket]),
    do: {:noreply, assign_theme_error(socket, function)}

  defp assign_theme_error(socket, function),
    do: assign(socket, :error, ErrorBoundary.format_error(%{function: function}))

  defp render_error(assigns, message) do
    assigns = assign(assigns, :error_message, message)

    ~H"""
    <div class="min-h-screen bg-tymeslot-100 flex items-center justify-center">
      <div class="bg-white p-8 rounded-lg shadow-md max-w-md w-full">
        <div class="text-center">
          <div class="text-red-500 text-6xl mb-4">⚠️</div>
          <h1 class="theme-error-title text-xl font-bold text-tymeslot-900 mb-2">
            {dgettext("booking", "Something went wrong")}
          </h1>
          <p class="text-tymeslot-600 mb-4">{@error_message}</p>
          <button
            id="theme-error-retry-button"
            phx-hook="PageReload"
            class="bg-blue-500 hover:bg-blue-600 text-white px-4 py-2 rounded"
          >
            {dgettext("booking", "Try again")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
