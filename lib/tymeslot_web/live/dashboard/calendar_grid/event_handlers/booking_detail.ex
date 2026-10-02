defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.BookingDetail do
  @moduledoc "Open/close handlers for the read-only booking detail modal."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Agenda
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_show_booking(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_booking(%{"meeting-id" => id_str}, socket) when is_binary(id_str) do
    # Meeting ids are UUIDs, so the incoming param is matched as a string
    # rather than parsed. An unknown id simply selects nothing. The modal
    # describes the booking as an agenda entry, like the overview's.
    booking =
      Enum.find(
        socket.assigns.events,
        &(Helpers.booking?(&1) and to_string(&1.meeting_id) == id_str)
      )

    entry = booking && Agenda.entry_for_grid_event(booking, socket.assigns.user_timezone)

    {:noreply, assign(socket, :selected_booking, entry)}
  end

  @spec handle_close_booking_detail(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_booking_detail(_params, socket) do
    {:noreply, assign(socket, :selected_booking, nil)}
  end
end
