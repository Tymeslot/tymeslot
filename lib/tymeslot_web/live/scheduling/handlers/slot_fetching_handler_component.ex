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
  - `load_slots/2` - Load slots for a specific date
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Demo
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  @doc """
  Fetches available slots for a given date and timezone.

  The `duration` argument is accepted for message-contract compatibility
  with callers but is not used to select the fetch: the duration is always
  resolved from the socket via `AvailabilityHelpers.duration_minutes/1`, so
  the offered slots can't drift from the duration the domain will validate
  against.

  This function:
  1. Calls the backend to get available slots
  2. Updates the socket with slots or error state
  3. Clears loading state

  ## Examples

      case SlotFetchingHandlerComponent.fetch_available_slots(socket, date, _duration, "America/New_York") do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec fetch_available_slots(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          term(),
          String.t()
        ) :: {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def fetch_available_slots(socket, date, _duration, timezone) do
    # Prepare context map for better performance and to avoid extra DB lookups in core.
    # `Demo.demo_mode?/1` is computed fresh from the socket here (mirroring
    # `AvailabilityHelpers.perform_availability_fetch/1`) rather than read
    # from a `:demo_mode` socket assign: nothing in Core ever sets one — the
    # write side (`TemplateDemo.Context.put_demo_mode/2`) was removed as
    # unreachable, so reading `socket.assigns[:demo_mode]` here always
    # resolved to `nil`, silently disabling demo detection on this path.
    context = %{
      demo_mode: Demo.demo_mode?(socket),
      organizer_profile: socket.assigns.organizer_profile,
      meeting_type: socket.assigns[:meeting_type],
      debug_calendar_module: socket.private[:debug_calendar_module]
    }

    # Single resolver for display and submit, so the offered slots can't
    # drift from the duration the domain will validate against.
    duration_to_fetch = AvailabilityHelpers.duration_minutes(socket)

    # `:expanded_hour` is deliberately left untouched here. Resetting it on
    # every fetch would spring a deliberately collapsed `:none` back open on
    # a refetch the booker did not ask for (a timezone change, a lost-slot
    # retry): those call this function for the *same* date, and it has
    # nothing to do with the booker's previous hour selection. An explicit
    # date pick — the one case that must reset it, since the open hour would
    # describe a grid that no longer applies — resets it at the point the
    # booker makes that choice, in `handle_schedule_date_selection/2`.
    case AvailabilityHelpers.get_available_slots(
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
          |> assign(:slot_interval_minutes, AvailabilityHelpers.slot_interval_minutes(socket))
          |> assign(:duration_minutes, duration_to_fetch)
          |> assign(:loading_slots, false)
          |> assign(:calendar_error, nil)

        {:ok, socket}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to fetch available slots", reason: inspect(reason))

        socket =
          socket
          |> assign(:available_slots, [])
          |> assign(:slot_interval_minutes, AvailabilityHelpers.slot_interval_minutes(socket))
          |> assign(:duration_minutes, duration_to_fetch)
          |> assign(:loading_slots, false)
          # Deliberately says nothing about *why*. This is the most
          # conversion-critical screen in the product, and a booker who has
          # never heard of a calendar provider can act on "try again" but
          # not on a parser. The reason is in the log line above, where the
          # person who can act on it will look.
          |> assign(
            :calendar_error,
            dgettext("booking", "No time slots could be loaded. Please try again.")
          )

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
