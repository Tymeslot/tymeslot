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
  - `handle_timezone_search/2` - Filter timezone search results
  - `handle_timezone_dropdown_toggle/1` - Toggle dropdown state
  - `handle_timezone_dropdown_close/1` - Close dropdown
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
        |> tap(fn _ ->
          send(self(), {:fetch_available_slots, selected_date, duration, new_timezone})
        end)
    end
  end

  @doc """
  Handles timezone search functionality.

  Processes search input and updates the timezone search state.

  ## Examples

      case TimezoneHandlerComponent.handle_timezone_search(socket, %{"search" => "New York"}) do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec handle_timezone_search(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_timezone_search(socket, params) do
    search_term =
      case params do
        %{"search" => term} -> term
        %{"value" => term} -> term
        %{"_target" => ["search"], "search" => term} -> term
        _ -> ""
      end

    socket =
      socket
      |> assign(:timezone_search, search_term)
      |> assign(:timezone_dropdown_open, true)

    {:ok, socket}
  end

  @doc """
  Toggles the timezone dropdown state.

  ## Examples

      {:ok, socket} = TimezoneHandlerComponent.handle_timezone_dropdown_toggle(socket)
  """
  @spec handle_timezone_dropdown_toggle(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_timezone_dropdown_toggle(socket) do
    current_state = socket.assigns[:timezone_dropdown_open] || false
    socket = assign(socket, :timezone_dropdown_open, !current_state)
    {:ok, socket}
  end

  @doc """
  Closes the timezone dropdown.

  ## Examples

      {:ok, socket} = TimezoneHandlerComponent.handle_timezone_dropdown_close(socket)
  """
  @spec handle_timezone_dropdown_close(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_timezone_dropdown_close(socket) do
    socket = assign(socket, :timezone_dropdown_open, false)
    {:ok, socket}
  end
end
