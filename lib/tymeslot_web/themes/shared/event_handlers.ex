defmodule TymeslotWeb.Themes.Shared.EventHandlers do
  @moduledoc """
  Shared event handlers for theme scheduling LiveViews.
  """
  require Logger

  alias Phoenix.LiveView
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Themes.Shared.LiveHelpers
  import Phoenix.Component, only: [assign: 3]

  @doc """
  Handles toggling the language dropdown.
  """
  @spec handle_toggle_language_dropdown(LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_toggle_language_dropdown(socket) do
    {:noreply, assign(socket, :language_dropdown_open, !socket.assigns.language_dropdown_open)}
  end

  @doc """
  Handles closing the language dropdown.
  """
  @spec handle_close_language_dropdown(LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_close_language_dropdown(socket) do
    {:noreply, assign(socket, :language_dropdown_open, false)}
  end

  @doc """
  Handles locale change with a full page redirect to ensure the session is updated.
  Using a full redirect (external: true) is necessary because session updates
  can only happen over HTTP, not via WebSocket/LiveView client-side navigation.
  """
  @spec handle_change_locale(LiveView.Socket.t(), String.t(), module()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_change_locale(socket, locale, path_handlers_module) do
    path =
      socket
      |> path_handlers_module.build_path_with_locale(locale)
      |> LiveHelpers.tracking_path(socket.assigns[:tracking])

    {:noreply, LiveView.redirect(socket, external: path)}
  end

  @doc """
  Handles common timezone change logic.
  """
  @spec handle_timezone_change(LiveView.Socket.t(), map(), module()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_timezone_change(socket, data, timezone_handler_module) do
    case timezone_handler_module.handle_timezone_change(socket, data) do
      {:ok, updated_socket} ->
        {:noreply, updated_socket}

      {:error, reason} ->
        Logger.warning("Timezone change failed", reason: inspect(reason))
        {:noreply, socket}
    end
  end

  @doc """
  Handles overview step events.
  """
  @spec handle_overview_events(LiveView.Socket.t(), atom(), any(), map()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_overview_events(socket, event, data, callbacks) do
    case event do
      :select_duration ->
        socket =
          socket
          |> assign(:selected_duration, data)
          |> assign(:duration, data)
          |> callbacks.maybe_assign_meeting_type.(data)
          # Trigger availability refresh when duration changes
          |> AvailabilityHelpers.fetch_month_availability_async()

        {:noreply, socket}

      :next_step ->
        handle_state_transition(socket, :overview, :schedule, callbacks)

      _other ->
        {:noreply, socket}
    end
  end

  @doc """
  Handles timezone-related events.
  """
  @spec handle_timezone_events(LiveView.Socket.t(), atom(), any(), map()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_timezone_events(socket, event, data, callbacks) do
    case event do
      :change_timezone ->
        handle_timezone_change(socket, data, callbacks.timezone_handler_component)

      :search_timezone ->
        callbacks.handle_timezone_search.(socket, data)

      :toggle_timezone_dropdown ->
        {:noreply,
         assign(socket, :timezone_dropdown_open, !socket.assigns[:timezone_dropdown_open])}

      :close_timezone_dropdown ->
        Process.send_after(self(), :close_dropdown, 150)
        {:noreply, socket}
    end
  end

  @doc """
  Handles timezone search input updates.
  """
  @spec handle_timezone_search(LiveView.Socket.t(), map()) :: {:noreply, LiveView.Socket.t()}
  def handle_timezone_search(socket, params) do
    search_term =
      case params do
        %{"search" => term} -> term
        %{"value" => term} -> term
        %{"_target" => ["search"], "search" => term} -> term
        _other -> ""
      end

    socket =
      socket
      |> assign(:timezone_search, search_term)
      |> assign(:timezone_dropdown_open, true)

    {:noreply, socket}
  end

  @doc """
  Handles state transitions with validation.
  """
  @spec handle_state_transition(LiveView.Socket.t(), atom(), atom(), map()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_state_transition(socket, current_state, next_state, callbacks) do
    case callbacks.validate_state_transition.(socket, current_state, next_state) do
      :ok ->
        socket = callbacks.transition_to.(socket, next_state, %{})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, LiveView.put_flash(socket, :error, reason)}
    end
  end
end
