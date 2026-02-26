defmodule TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent do
  @moduledoc """
  Specialized handler for slot fetching operations in scheduling themes.

  This handler provides common slot fetching functionality that can be used across
  different themes, eliminating code duplication while maintaining theme independence.

  ## Usage

      alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent

      # In your theme's handle_info callback:
      def handle_info({:fetch_available_slots, date, duration, timezone}, socket) do
        case SlotFetchingHandlerComponent.fetch_available_slots(socket, date, duration, timezone) do
          {:ok, updated_socket} -> {:noreply, updated_socket}
          {:error, error_socket} -> {:noreply, error_socket}
        end
      end

  ## Available Functions

  - `fetch_available_slots/4` - Fetch available time slots for a given date
  - `maybe_reload_slots/1` - Conditionally reload slots if date is selected
  - `handle_calendar_error/2` - Process calendar errors gracefully
  """

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Live.Scheduling.Helpers

  @doc """
  Fetches available slots for a given date, duration, and timezone.

  This function:
  1. Calls the backend to get available slots
  2. Updates the socket with slots or error state
  3. Clears loading state

  ## Examples

      case SlotFetchingHandlerComponent.fetch_available_slots(socket, date, "30min", "America/New_York") do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec fetch_available_slots(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t() | integer(),
          String.t()
        ) :: {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def fetch_available_slots(socket, date, duration, timezone) do
    # Prepare context map for better performance and to avoid extra DB lookups in core
    context = %{
      demo_mode: socket.assigns[:demo_mode],
      organizer_profile: socket.assigns.organizer_profile,
      debug_calendar_module: socket.private[:debug_calendar_module]
    }

    # Prefer the integer from meeting_type to avoid slug-parsing issues
    duration_to_fetch =
      case socket.assigns[:meeting_type] do
        %{duration_minutes: mins} when is_integer(mins) -> mins
        _other -> duration
      end

    case Helpers.get_available_slots(
           date,
           duration_to_fetch,
           timezone,
           socket.assigns.organizer_user_id,
           socket.assigns.organizer_profile,
           context
         ) do
      {:ok, slots} ->
        socket =
          socket
          |> assign(:available_slots, slots)
          |> assign(:loading_slots, false)
          |> assign(:calendar_error, nil)

        {:ok, socket}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to fetch available slots", reason: inspect(reason))

        socket =
          socket
          |> assign(:available_slots, [])
          |> assign(:loading_slots, false)
          |> assign(:calendar_error, "No timeslots available due to calendar parsing error")

        {:error, socket}
    end
  end

  @doc """
  Conditionally reloads slots if a date is currently selected.

  This function checks if there's a selected date and triggers slot reloading
  if necessary. Useful after timezone changes or other state updates.

  ## Examples

      {:ok, socket} = SlotFetchingHandlerComponent.maybe_reload_slots(socket)
  """
  @spec maybe_reload_slots(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def maybe_reload_slots(socket) do
    case socket.assigns[:selected_date] do
      nil ->
        {:ok, socket}

      selected_date ->
        duration = socket.assigns[:duration] || socket.assigns[:selected_duration]
        timezone = socket.assigns[:user_timezone]

        socket =
          socket
          |> assign(:loading_slots, true)
          |> assign(:calendar_error, nil)
          |> tap(fn _client ->
            send(self(), {:fetch_available_slots, selected_date, duration, timezone})
          end)

        {:ok, socket}
    end
  end

  @doc """
  Handles calendar errors gracefully.

  This function processes calendar errors and updates the socket state
  with appropriate error messages and fallback states.

  ## Examples

      {:ok, socket} = SlotFetchingHandlerComponent.handle_calendar_error(socket, "Connection timeout")
  """
  @spec handle_calendar_error(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_calendar_error(socket, reason) do
    error_message =
      case reason do
        "timeout" -> "Calendar is temporarily unavailable. Please try again later."
        "connection_error" -> "Unable to connect to calendar service."
        _other -> "No timeslots available due to calendar parsing error"
      end

    socket =
      socket
      |> assign(:available_slots, [])
      |> assign(:loading_slots, false)
      |> assign(:calendar_error, error_message)

    {:ok, socket}
  end

  @doc """
  Loads slots for a specific date.

  This is a convenience function that sends a message to trigger slot fetching.

  ## Examples

      SlotFetchingHandlerComponent.load_slots(socket, "2024-01-15")
  """
  @spec load_slots(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def load_slots(socket, date) do
    duration = socket.assigns[:duration] || socket.assigns[:selected_duration]
    timezone = socket.assigns[:user_timezone]

    send(self(), {:fetch_available_slots, date, duration, timezone})

    socket =
      socket
      |> assign(:loading_slots, true)
      |> assign(:calendar_error, nil)

    {:ok, socket}
  end
end
