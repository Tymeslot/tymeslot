defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Search do
  @moduledoc """
  Event-search handlers for CalendarGridComponent (presentation layer).

  Drives the toolbar search box: running a query, jumping the grid to a
  selected match, and closing the results panel.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_search(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_search(%{"term" => term}, socket) do
    user_id = socket.assigns.current_user.id
    hidden_ids = socket.assigns.hidden_integration_ids
    results = CalendarGrid.search_events(user_id, term, hidden_integration_ids: hidden_ids)

    {:noreply,
     socket
     |> assign(:search_term, term)
     |> assign(:search_results, results)
     |> assign(:search_open, String.trim(term) != "")}
  end

  def handle_search(_params, socket), do: {:noreply, socket}

  @spec handle_close_search(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_search(_params, socket) do
    {:noreply, assign(socket, :search_open, false)}
  end

  @spec handle_goto_search_result(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_goto_search_result(%{"event-id" => id_str, "date" => date_str}, socket) do
    with {:ok, event_id} <- Shared.parse_int(id_str),
         {:ok, date} <- Date.from_iso8601(date_str) do
      socket =
        socket
        |> assign(:view, :day)
        |> assign(:date, date)
        |> Helpers.load_events()
        |> assign(:search_open, false)
        |> select_event(event_id)

      {:noreply, socket}
    else
      _error -> {:noreply, socket}
    end
  end

  def handle_goto_search_result(_params, socket), do: {:noreply, socket}

  # After reloading the day's events, surface the chosen event in the detail
  # modal. The reload guarantees the event is in scope when its date is shown.
  defp select_event(socket, event_id) do
    case Enum.find(socket.assigns.events, &(&1.id == event_id)) do
      nil ->
        socket

      event ->
        socket
        |> assign(:selected_event, event)
        |> assign(:pending_attendees, [])
        |> assign(:attendee_input, "")
        |> assign(:pending_notification, false)
    end
  end
end
