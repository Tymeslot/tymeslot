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

  @doc """
  Handles timezone changes with automatic slot reloading.

  This function:
  1. Updates the user's timezone
  2. Clears the selected time
  3. Closes the timezone dropdown
  4. Reloads available slots if a date is selected

  ## Examples

      case TimezoneHandlerComponent.handle_timezone_change(socket, "America/New_York") do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec handle_timezone_change(Phoenix.LiveView.Socket.t(), String.t() | map()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_timezone_change(socket, data) do
    new_timezone = extract_timezone(data)

    socket = update_timezone(socket, new_timezone)

    if socket.assigns.user_timezone != new_timezone do
      {:ok, socket}
    else
      socket =
        socket
        |> assign(:selected_time, nil)
        |> assign(:available_slots, [])
        |> assign(:timezone_dropdown_open, false)
        |> assign(:timezone_search, "")
        |> maybe_trigger_slot_reload(new_timezone)

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
end
