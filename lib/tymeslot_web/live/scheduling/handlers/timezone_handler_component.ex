defmodule TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent do
  @moduledoc """
  Specialized handler for timezone-related operations in scheduling themes.

  This handler provides common timezone functionality that can be used across
  different themes, eliminating code duplication while maintaining theme independence.

  ## Usage

      alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

      # In your theme's handle_info callback:
      def handle_info({:step_event, :schedule, :change_timezone, data}, socket) do
        case TimezoneHandlerComponent.handle_timezone_change(socket, data) do
          {:ok, updated_socket} -> {:noreply, updated_socket}
          {:error, error_socket} -> {:noreply, error_socket}
        end
      end

  ## Available Functions

  - `handle_timezone_change/2` - Process timezone updates and reload slots
  """

  import Phoenix.Component, only: [assign: 3]
  import TymeslotWeb.Live.Shared.LiveHelpers, only: [update_timezone: 2]

  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  @doc """
  Handles timezone changes, recomputing what the page offers in the new zone.

  This function:
  1. Updates the user's timezone
  2. Clears the selected time
  3. Closes the timezone dropdown
  4. Reloads available slots if a date is selected
  5. Refetches the month availability when the zone actually changed, since
     which days are bookable depends on the zone they are read in

  A rejected timezone leaves the socket untouched. The selected date is kept
  even when it has no times in the new zone: the slot list then shows its
  empty state, as it does after a calendar sync empties the day.

  ## Examples

      case TimezoneHandlerComponent.handle_timezone_change(socket, "America/New_York") do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec handle_timezone_change(Phoenix.LiveView.Socket.t(), String.t() | map()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_timezone_change(socket, data) do
    requested = data |> extract_timezone() |> Timezones.normalize()
    previous = socket.assigns.user_timezone

    socket = update_timezone(socket, requested)

    if socket.assigns.user_timezone != requested do
      {:ok, socket}
    else
      socket =
        socket
        |> assign(:selected_time, nil)
        |> assign(:available_slots, [])
        |> assign(:timezone_dropdown_open, false)
        |> assign(:timezone_search, "")
        |> maybe_trigger_slot_reload(requested)
        |> maybe_refetch_month(previous)

      {:ok, socket}
    end
  end

  defp extract_timezone(data) when is_binary(data), do: data
  defp extract_timezone(%{timezone: tz}) when is_binary(tz), do: tz
  defp extract_timezone(%{"timezone" => tz}) when is_binary(tz), do: tz
  defp extract_timezone(other), do: other

  defp maybe_trigger_slot_reload(socket, new_timezone) do
    case socket.assigns.selected_date do
      nil ->
        socket

      selected_date ->
        duration = socket.assigns.duration || socket.assigns.selected_duration

        socket
        |> assign(:loading_slots, true)
        |> assign(:calendar_error, nil)
        |> tap(fn _client ->
          send(self(), {:fetch_available_slots, selected_date, duration, new_timezone})
        end)
    end
  end

  # The month grid's bookable days are computed in the booker's zone, so a
  # new zone needs a new map. `fetch_month_availability_async/1` cancels the
  # fetch in flight and replaces its ref, so a result computed for the old
  # zone that arrives afterwards is discarded rather than painted.
  defp maybe_refetch_month(%{assigns: %{user_timezone: previous}} = socket, previous),
    do: socket

  defp maybe_refetch_month(socket, _previous),
    do: AvailabilityHelpers.fetch_month_availability_async(socket)
end
