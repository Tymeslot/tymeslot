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

  - `handle_timezone_change/2` - Process timezone updates
  """

  import Phoenix.Component, only: [assign: 3]
  import TymeslotWeb.Live.Shared.LiveHelpers, only: [resolve_timezone: 1]

  @doc """
  Handles timezone changes.

  This function:
  1. Updates the user's timezone
  2. Clears the selected time and the slots listed for the old zone
  3. Closes the timezone dropdown

  It reloads no slots. Which day stays selected is decided after the zone
  has changed (`NextAvailable.follow_timezone_change/1`), and the caller
  reloads the slots of whichever day that is; reloading here would fetch
  them, synchronously, for a day that may be dropped a moment later.

  ## Examples

      case TimezoneHandlerComponent.handle_timezone_change(socket, "America/New_York") do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec handle_timezone_change(Phoenix.LiveView.Socket.t(), String.t() | map()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_timezone_change(socket, data) do
    previous = socket.assigns[:user_timezone]

    case data |> extract_timezone() |> resolve_timezone() do
      # The zone already in use, picked again, in any spelling: nothing to redo.
      {:ok, ^previous} ->
        {:ok, close_picker(socket)}

      # Another zone: the time chosen and the slots listed were the old zone's.
      {:ok, timezone} ->
        {:ok,
         socket
         |> assign(:user_timezone, timezone)
         |> assign(:selected_time, nil)
         |> assign(:available_slots, [])
         |> close_picker()}

      # A zone that failed validation leaves everything as it was.
      :error ->
        {:ok, socket}
    end
  end

  defp close_picker(socket) do
    socket
    |> assign(:timezone_dropdown_open, false)
    |> assign(:timezone_search, "")
  end

  defp extract_timezone(data) when is_binary(data), do: data
  defp extract_timezone(%{timezone: tz}) when is_binary(tz), do: tz
  defp extract_timezone(%{"timezone" => tz}) when is_binary(tz), do: tz
  defp extract_timezone(other), do: other
end
